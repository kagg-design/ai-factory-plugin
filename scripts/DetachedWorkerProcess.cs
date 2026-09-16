using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudeFactory
{
    // Start the short-lived worker launcher with a private environment and no
    // inherited pipes. Only it opens the worker's stdin/stdout/stderr files.
    public static class DetachedWorkerProcess
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int cb;
            public string reserved, desktop, title;
            public int x, y, xSize, ySize, xChars, yChars, fill, flags;
            public short show, reservedSize;
            public IntPtr reservedPointer, stdin, stdout, stderr;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInfo
        {
            public IntPtr process, thread;
            public int pid, tid;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcess(string application, StringBuilder command,
            IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles,
            uint flags, IntPtr environment, string cwd, ref StartupInfo startup, out ProcessInfo process);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        public static int Start(string application, string arguments, string cwd, IDictionary overrides)
        {
            var values = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (DictionaryEntry item in Environment.GetEnvironmentVariables())
                values[(string)item.Key] = (string)item.Value;
            foreach (DictionaryEntry item in overrides)
            {
                if (item.Value == null) values.Remove((string)item.Key);
                else values[(string)item.Key] = item.Value.ToString();
            }
            var block = new StringBuilder();
            foreach (var item in values) block.Append(item.Key).Append('=').Append(item.Value).Append('\0');
            block.Append('\0');
            IntPtr env = Marshal.StringToHGlobalUni(block.ToString());
            try
            {
                var startup = new StartupInfo();
                startup.cb = Marshal.SizeOf(typeof(StartupInfo));
                ProcessInfo process;
                var command = new StringBuilder("\"" + application + "\" " + arguments);
                if (!CreateProcess(application, command, IntPtr.Zero, IntPtr.Zero, false,
                    0x08000000 | 0x00000400, env, cwd, ref startup, out process))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                try { return process.pid; }
                finally { CloseHandle(process.thread); CloseHandle(process.process); }
            }
            finally { Marshal.FreeHGlobal(env); }
        }
    }
}
