// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;

public sealed class LocalSafeInstance : IDisposable
{
    private Mutex mutex;
    private LocalSafeInstance(Mutex value) { mutex = value; }
    private static string UserKey { get { return WindowsIdentity.GetCurrent().User.Value; } }
    private static string WindowTag { get { return "LocalSafe.MainWindow." + UserKey; } }
    public static readonly uint ActivationMessage = RegisterWindowMessage("LocalSafe.Activate.v1");

    public static LocalSafeInstance TryAcquire(string name)
    {
        Mutex candidate = new Mutex(false, name);
        bool acquired;
        try { acquired = candidate.WaitOne(0); }
        catch (AbandonedMutexException) { acquired = true; }
        if (acquired) return new LocalSafeInstance(candidate);
        candidate.Dispose();
        return null;
    }
    public static LocalSafeInstance TryAcquire() { return TryAcquire("Local\\LocalSafe.Instance." + UserKey); }
    public void Dispose()
    {
        if (mutex == null) return;
        mutex.ReleaseMutex(); mutex.Dispose(); mutex = null;
    }
    public static void AttachMainWindow(IntPtr window)
    {
        if (!SetProp(window, WindowTag, new IntPtr(1))) throw new System.ComponentModel.Win32Exception();
        // Only the fixed activation message is accepted across integrity levels.
        if (!ChangeWindowMessageFilterEx(window, ActivationMessage, 1, IntPtr.Zero))
            throw new System.ComponentModel.Win32Exception();
    }
    public static bool TryActivateExisting()
    {
        bool activated = false;
        EnumWindows(delegate(IntPtr window, IntPtr state)
        {
            if (GetProp(window, WindowTag) == IntPtr.Zero) return true;
            uint pid; GetWindowThreadProcessId(window, out pid);
            AllowSetForegroundWindow(pid);
            activated = PostMessage(window, ActivationMessage, IntPtr.Zero, IntPtr.Zero);
            return !activated;
        }, IntPtr.Zero);
        return activated;
    }
    public static void ActivateWindow(IntPtr window)
    {
        if (IsIconic(window)) ShowWindow(window, 9);
        IntPtr popup = GetLastActivePopup(window);
        if (popup == IntPtr.Zero || !IsWindowVisible(popup)) popup = window;
        if (IsIconic(popup)) ShowWindow(popup, 9);
        SetForegroundWindow(popup);
    }
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr state);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern uint RegisterWindowMessage(string message);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool SetProp(IntPtr window, string name, IntPtr value);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr GetProp(IntPtr window, string name);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool ChangeWindowMessageFilterEx(IntPtr window, uint message, uint action, IntPtr changeInfo);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] private static extern bool AllowSetForegroundWindow(uint processId);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetLastActivePopup(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
}
