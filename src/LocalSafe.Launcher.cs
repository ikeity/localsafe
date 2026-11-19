// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.IO;
using System.ComponentModel;
using System.Diagnostics;
using System.Security.Principal;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyVersion("0.3.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("0.3.0.0")]
[assembly: System.Reflection.AssemblyProduct("LocalSafe")]

internal static class LocalSafeLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            // The release ZIP keeps the scripts beside the native launcher.
            if (args.Length == 0)
                args = new string[] { Path.Combine(Application.StartupPath, "src", "LocalSafe.Gui.ps1") };
            if (args.Length != 1 || !File.Exists(args[0]))
                throw new ArgumentException("LocalSafe requires its GUI script path.");
            // Repeated normal launches can activate an elevated instance without another UAC.
            if (LocalSafeInstance.TryActivateExisting()) return 0;
            // Request elevation before loading any inventory or opening the GUI.
            // The relaunched process checks its token, so no elevation loop occurs.
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
            {
                if (!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
                {
                    try
                    {
                        Process.Start(new ProcessStartInfo
                        {
                            FileName = Application.ExecutablePath,
                            Arguments = "\"" + Path.GetFullPath(args[0]) + "\"",
                            UseShellExecute = true,
                            Verb = "runas",
                            WorkingDirectory = Path.GetDirectoryName(Path.GetFullPath(args[0]))
                        });
                        return 0;
                    }
                    catch (Win32Exception error)
                    {
                        if (error.NativeErrorCode != 1223) throw;
                        MessageBox.Show("Administrator approval was cancelled. LocalSafe has not started.",
                            "LocalSafe", MessageBoxButtons.OK, MessageBoxIcon.Information);
                        return 2;
                    }
                }
            }
            using (LocalSafeInstance instance = LocalSafeInstance.TryAcquire())
            {
            if (instance == null)
            {
                // Another launch may still be creating its first window.
                for (int i = 0; i < 100; i++)
                {
                    if (LocalSafeInstance.TryActivateExisting()) return 0;
                    Thread.Sleep(100);
                }
                MessageBox.Show("LocalSafe is already starting or running.", "LocalSafe",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 0;
            }
            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                // Process scope only; never modify the machine execution policy.
                using (PowerShell shell = PowerShell.Create())
                {
                    shell.Runspace = runspace;
                    shell.AddCommand("Set-ExecutionPolicy").AddParameter("Scope", "Process")
                        .AddParameter("ExecutionPolicy", "Bypass").AddParameter("Force").Invoke();
                    shell.Commands.Clear();
                    shell.AddCommand(Path.GetFullPath(args[0]));
                    shell.Invoke();
                    if (shell.HadErrors)
                        throw new InvalidOperationException(shell.Streams.Error.ToString());
                }
            }
            }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "LocalSafe", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
