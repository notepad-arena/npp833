// This file is part of Notepad++ project
// Copyright (C)2021 Don HO <don.h@free.fr>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// at your option any later version.
//
// COM plumbing for the packaged context menu handler: class factory plus the two DLL exports
// the COM surrogate (dllhost.exe) looks for.

#include "NppExplorerCommand.h"

#include <new>

namespace
{
    HINSTANCE g_instance = nullptr;
    LONG g_serverLocks = 0;    // outstanding class factories + command objects

    class CNppClassFactory : public IClassFactory
    {
    public:
        CNppClassFactory() : _refCount(1)
        {
            ::InterlockedIncrement(&g_serverLocks);
        }

        // IUnknown
        IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override
        {
            if (ppv == nullptr)
            {
                return E_POINTER;
            }
            *ppv = nullptr;
            if (riid == IID_IUnknown || riid == IID_IClassFactory)
            {
                *ppv = static_cast<IClassFactory*>(this);
                AddRef();
                return S_OK;
            }
            return E_NOINTERFACE;
        }

        IFACEMETHODIMP_(ULONG) AddRef() override
        {
            return ::InterlockedIncrement(&_refCount);
        }

        IFACEMETHODIMP_(ULONG) Release() override
        {
            const ULONG count = ::InterlockedDecrement(&_refCount);
            if (count == 0)
            {
                ::InterlockedDecrement(&g_serverLocks);
                delete this;
            }
            return count;
        }

        // IClassFactory
        IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override
        {
            if (ppv == nullptr)
            {
                return E_POINTER;
            }
            *ppv = nullptr;
            if (outer != nullptr)
            {
                return CLASS_E_NOAGGREGATION;
            }

            CNppExplorerCommand* command = new (std::nothrow) CNppExplorerCommand();
            if (command == nullptr)
            {
                return E_OUTOFMEMORY;
            }

            const HRESULT hr = command->QueryInterface(riid, ppv);
            command->Release();
            return hr;
        }

        IFACEMETHODIMP LockServer(BOOL lock) override
        {
            if (lock)
            {
                ::InterlockedIncrement(&g_serverLocks);
            }
            else
            {
                ::InterlockedDecrement(&g_serverLocks);
            }
            return S_OK;
        }

    private:
        ~CNppClassFactory()
        {
        }

        LONG _refCount;
    };
}

// NOTE: combaseapi.h declares DllGetClassObject / DllCanUnloadNow with DECLSPEC_IMPORT (client
// side), so defining them here directly conflicts (C2375). The real export names are produced by
// NppShellMsix.def, which aliases them to NppDllGetClassObject / NppDllCanUnloadNow below.
// Called by CNppExplorerCommand's ctor / dtor so the module is not unloaded mid-call.
void NppServerAddRef()
{
    ::InterlockedIncrement(&g_serverLocks);
}

void NppServerRelease()
{
    ::InterlockedDecrement(&g_serverLocks);
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID /*reserved*/)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        g_instance = module;
        ::DisableThreadLibraryCalls(module);
    }
    return TRUE;
}

extern "C" HRESULT __stdcall NppDllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv)
{
    if (ppv == nullptr)
    {
        return E_POINTER;
    }
    *ppv = nullptr;

    if (!::IsEqualCLSID(rclsid, __uuidof(CNppExplorerCommand)))
    {
        return CLASS_E_CLASSNOTAVAILABLE;
    }

    CNppClassFactory* factory = new (std::nothrow) CNppClassFactory();
    if (factory == nullptr)
    {
        return E_OUTOFMEMORY;
    }

    const HRESULT hr = factory->QueryInterface(riid, ppv);
    factory->Release();
    return hr;
}

extern "C" HRESULT __stdcall NppDllCanUnloadNow(void)
{
    return (::InterlockedCompareExchange(&g_serverLocks, 0, 0) == 0) ? S_OK : S_FALSE;
}
