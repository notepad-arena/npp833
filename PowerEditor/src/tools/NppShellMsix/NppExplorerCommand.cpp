// This file is part of Notepad++ project
// Copyright (C)2021 Don HO <don.h@free.fr>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// at your option any later version.

#include "NppExplorerCommand.h"

#include <shlwapi.h>
#include <shellapi.h>
#include <string>
#include <vector>

#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")

namespace
{
    const wchar_t* const c_menuTitle = L"Edit with Notepad++";
    const wchar_t* const c_exeName = L"Notepad++.exe";

    // Directory the package (and therefore Notepad++.exe) lives in: the DLL sits next to it.
    std::wstring getPackageDir()
    {
        wchar_t path[MAX_PATH * 2] = { 0 };
        HMODULE self = nullptr;
        if (!::GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                  reinterpret_cast<LPCWSTR>(&getPackageDir), &self))
        {
            return std::wstring();
        }
        DWORD len = ::GetModuleFileNameW(self, path, ARRAYSIZE(path));
        if (len == 0 || len >= ARRAYSIZE(path))
        {
            return std::wstring();
        }
        std::wstring dir(path, len);
        const size_t slash = dir.find_last_of(L"\\/");
        if (slash == std::wstring::npos)
        {
            return std::wstring();
        }
        dir.erase(slash);
        return dir;
    }

    std::wstring getExePath()
    {
        const std::wstring dir = getPackageDir();
        if (dir.empty())
        {
            return std::wstring();
        }
        return dir + L"\\" + c_exeName;
    }

    std::wstring quoteArg(const std::wstring& s)
    {
        std::wstring out = L"\"";
        out += s;
        out += L"\"";
        return out;
    }

    // Collect the selected items as filesystem paths.
    std::vector<std::wstring> getSelectedPaths(IShellItemArray* items)
    {
        std::vector<std::wstring> paths;
        if (items == nullptr)
        {
            return paths;
        }

        DWORD count = 0;
        if (FAILED(items->GetCount(&count)))
        {
            return paths;
        }

        for (DWORD i = 0; i < count; ++i)
        {
            IShellItem* item = nullptr;
            if (FAILED(items->GetItemAt(i, &item)) || item == nullptr)
            {
                continue;
            }

            PWSTR filePath = nullptr;
            if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &filePath)) && filePath != nullptr)
            {
                paths.emplace_back(filePath);
                ::CoTaskMemFree(filePath);
            }
            item->Release();
        }
        return paths;
    }
}

CNppExplorerCommand::CNppExplorerCommand() : _refCount(1)
{
    NppServerAddRef();
}

CNppExplorerCommand::~CNppExplorerCommand()
{
    NppServerRelease();
}

IFACEMETHODIMP CNppExplorerCommand::QueryInterface(REFIID riid, void** ppv)
{
    if (ppv == nullptr)
    {
        return E_POINTER;
    }
    *ppv = nullptr;

    if (riid == IID_IUnknown || riid == IID_IExplorerCommand)
    {
        *ppv = static_cast<IExplorerCommand*>(this);
    }
    else
    {
        return E_NOINTERFACE;
    }

    AddRef();
    return S_OK;
}

IFACEMETHODIMP_(ULONG) CNppExplorerCommand::AddRef()
{
    return ::InterlockedIncrement(&_refCount);
}

IFACEMETHODIMP_(ULONG) CNppExplorerCommand::Release()
{
    const ULONG count = ::InterlockedDecrement(&_refCount);
    if (count == 0)
    {
        delete this;
    }
    return count;
}

IFACEMETHODIMP CNppExplorerCommand::GetTitle(IShellItemArray* /*psiItemArray*/, LPWSTR* ppszName)
{
    if (ppszName == nullptr)
    {
        return E_POINTER;
    }
    return ::SHStrDupW(c_menuTitle, ppszName);
}

IFACEMETHODIMP CNppExplorerCommand::GetIcon(IShellItemArray* /*psiItemArray*/, LPWSTR* ppszIcon)
{
    if (ppszIcon == nullptr)
    {
        return E_POINTER;
    }
    *ppszIcon = nullptr;

    const std::wstring exe = getExePath();
    if (exe.empty())
    {
        return E_NOTIMPL;
    }
    // "path,index" form: index 0 of Notepad++.exe
    const std::wstring icon = exe + L",0";
    return ::SHStrDupW(icon.c_str(), ppszIcon);
}

IFACEMETHODIMP CNppExplorerCommand::GetToolTip(IShellItemArray* /*psiItemArray*/, LPWSTR* ppszInfotip)
{
    if (ppszInfotip == nullptr)
    {
        return E_POINTER;
    }
    *ppszInfotip = nullptr;
    return E_NOTIMPL;
}

IFACEMETHODIMP CNppExplorerCommand::GetCanonicalName(GUID* pguidCommandName)
{
    if (pguidCommandName == nullptr)
    {
        return E_POINTER;
    }
    *pguidCommandName = __uuidof(CNppExplorerCommand);
    return S_OK;
}

IFACEMETHODIMP CNppExplorerCommand::GetState(IShellItemArray* psiItemArray, BOOL /*fOkToBeSlow*/, EXPCMDSTATE* pCmdState)
{
    if (pCmdState == nullptr)
    {
        return E_POINTER;
    }

    *pCmdState = getSelectedPaths(psiItemArray).empty() ? ECS_HIDDEN : ECS_ENABLED;
    return S_OK;
}

IFACEMETHODIMP CNppExplorerCommand::Invoke(IShellItemArray* psiItemArray, IBindCtx* /*pbc*/)
{
    const std::wstring exe = getExePath();
    if (exe.empty())
    {
        return E_FAIL;
    }

    const std::vector<std::wstring> paths = getSelectedPaths(psiItemArray);
    std::wstring args;
    for (const std::wstring& path : paths)
    {
        if (!args.empty())
        {
            args += L' ';
        }
        args += quoteArg(path);
    }

    const HINSTANCE result = ::ShellExecuteW(nullptr, L"open", exe.c_str(),
                                            args.empty() ? nullptr : args.c_str(),
                                            nullptr, SW_SHOWNORMAL);
    // ShellExecute returns a value > 32 on success.
    return (reinterpret_cast<INT_PTR>(result) > 32) ? S_OK : E_FAIL;
}

IFACEMETHODIMP CNppExplorerCommand::GetFlags(EXPCMDFLAGS* pFlags)
{
    if (pFlags == nullptr)
    {
        return E_POINTER;
    }
    *pFlags = ECF_DEFAULT;
    return S_OK;
}

IFACEMETHODIMP CNppExplorerCommand::EnumSubCommands(IEnumExplorerCommand** ppEnum)
{
    if (ppEnum == nullptr)
    {
        return E_POINTER;
    }
    *ppEnum = nullptr;
    return E_NOTIMPL;
}
