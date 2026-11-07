// Task-only native UI cancellation and public SCM observations. No driver-store or MSI ownership writes.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class MsiCancelAfter
{
    const uint ActionStart = 0x08000000, Info = 0x04000000, Progress = 0x0A000000, Error = 0x01000000;
    const uint Filter = (1u << 8) | (1u << 4) | (1u << 1) | (1u << 2) | (1u << 3) | (1u << 10);
    delegate int Handler(IntPtr context, uint type, uint record);
    [DllImport("msi.dll")] static extern uint MsiSetExternalUIRecord(Handler callback, uint filter, IntPtr context, out IntPtr previous);
    [DllImport("msi.dll", EntryPoint = "MsiSetExternalUIRecord")] static extern uint Restore(IntPtr callback, uint filter, IntPtr context, out IntPtr previous);
    [DllImport("msi.dll")] static extern uint MsiSetInternalUI(uint level, IntPtr window);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiEnableLogW(uint mode, string path, uint attributes);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiInstallProductW(string package, string properties);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiRecordGetStringW(uint record, uint field, StringBuilder value, ref uint size);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiFormatRecordW(uint install, uint record, StringBuilder value, ref uint size);
    [DllImport("msi.dll")] static extern int MsiRecordGetInteger(uint record, uint field);

    public sealed class Outcome
    {
        public uint ExitCode;
        public bool Armed, Cancelled, RemovalInfoSeen, CompletionProgressSeen, CompletionAborted;
        public string OwnedComponent, InfoMarker;
        public string Boundary = "owned-removal-info-then-progress";
        public int CancelProgressKind, CancelProgressTicks;
        public string[] Actions;
    }

    static string Field(uint record, uint field)
    {
        uint length = 0;
        uint error = MsiRecordGetStringW(record, field, null, ref length);
        if ((error != 0 && error != 234) || length > 65535) return "";
        var text = new StringBuilder((int)length + 1);
        length = (uint)text.Capacity;
        return MsiRecordGetStringW(record, field, text, ref length) == 0 ? text.ToString() : "";
    }

    static string InfoText(uint record)
    {
        uint length = 0;
        uint error = MsiFormatRecordW(0, record, null, ref length);
        if ((error == 0 || error == 234) && length <= 65535) {
            var text = new StringBuilder((int)length + 1);
            length = (uint)text.Capacity;
            if (MsiFormatRecordW(0, record, text, ref length) == 0) return text.ToString();
        }
        // A preformatted WcaLog record can expose the message directly in field 0 or 1.
        return Field(record, 0) + " | " + Field(record, 1);
    }

    static string TraceText(string value)
    {
        return value.Replace("\r", "\\r").Replace("\n", "\\n").Replace("\t", "\\t");
    }

    public static Outcome Run(string package, string properties, string component, string log, string trace)
    {
        if (String.IsNullOrWhiteSpace(component) || component.IndexOfAny(new char[] { '\r', '\n', '\t' }) >= 0)
            throw new ArgumentException("A specific owned component from the fixture staging receipt is required");
        string marker = "Driver uninstall: component=" + component + " knownCreatedPackage=1.";
        var outcome = new Outcome { OwnedComponent = component, InfoMarker = marker };
        var actions = new List<string>();
        var events = new List<string>();
        Handler callback = (context, type, record) => {
            uint message = type & 0xFF000000;
            if (message == ActionStart) {
                string action = Field(record, 1);
                actions.Add(action);
                events.Add("ACTION\t" + TraceText(action));
                if (outcome.Armed && !outcome.Cancelled && action.StartsWith("Rollback", StringComparison.OrdinalIgnoreCase)) {
                    outcome.Armed = false;
                    outcome.CompletionAborted = true;
                    events.Add("DISARM\trollback-before-forward-completion");
                }
            }
            else if (message == Error) {
                events.Add("ERROR\t" + TraceText(InfoText(record)));
                if (outcome.Armed && !outcome.Cancelled) {
                    outcome.Armed = false;
                    outcome.CompletionAborted = true;
                    events.Add("DISARM\terror-before-forward-completion");
                }
            }
            else if (message == Info) {
                string info = InfoText(record);
                events.Add("INFO\t" + TraceText(info));
                if (!outcome.Cancelled && !outcome.CompletionAborted && info.IndexOf(marker, StringComparison.OrdinalIgnoreCase) >= 0) {
                    outcome.RemovalInfoSeen = true;
                    outcome.Armed = true;
                    events.Add("ARM\t" + TraceText(marker));
                }
            }
            else if (message == Progress) {
                int kind = MsiRecordGetInteger(record, 1), ticks = MsiRecordGetInteger(record, 2);
                int field3 = MsiRecordGetInteger(record, 3), field4 = MsiRecordGetInteger(record, 4);
                events.Add("PROGRESS\t" + kind + "\t" + ticks + "\t" + field3 + "\t" + field4);
                // Ignore reset/explicit-mode/extend messages. An unexpected increment after
                // the marker invalidates this seam rather than arming a later unrelated record.
                if (outcome.Armed && !outcome.Cancelled && kind == 2 && ticks != 200000) {
                    outcome.Armed = false;
                    outcome.CompletionAborted = true;
                    events.Add("DISARM\tunexpected-increment-before-forward-completion");
                }
                // The production loop emits this increment only after ForwardUninstall succeeds.
                if (outcome.Armed && !outcome.Cancelled && kind == 2 && ticks == 200000) {
                    outcome.CompletionProgressSeen = true;
                    outcome.CancelProgressKind = kind;
                    outcome.CancelProgressTicks = ticks;
                    outcome.Cancelled = true;
                    events.Add("CANCEL\towned-forward-completed\t2\t200000");
                    return 2; // IDCANCEL at the supported progress callback, not queued ActionStart.
                }
            }
            return 0;
        };
        uint previousLevel = MsiSetInternalUI(2, IntPtr.Zero);
        IntPtr previous, ignored;
        if (MsiSetExternalUIRecord(callback, Filter, IntPtr.Zero, out previous) != 0) {
            MsiSetInternalUI(previousLevel, IntPtr.Zero);
            throw new InvalidOperationException("Cannot register MSI external UI");
        }
        try {
            uint error = MsiEnableLogW(0x1FFF, log, 2);
            if (error != 0) throw new InvalidOperationException("Cannot enable MSI log: " + error);
            outcome.ExitCode = MsiInstallProductW(package, properties);
            return outcome;
        }
        finally {
            outcome.Actions = actions.ToArray();
            try { File.WriteAllLines(trace, events, new UTF8Encoding(false)); }
            finally {
                Restore(previous, 0, IntPtr.Zero, out ignored);
                MsiSetInternalUI(previousLevel, IntPtr.Zero);
                GC.KeepAlive(callback);
            }
        }
    }
}

public static class Pr85ServiceObservation
{
    [StructLayout(LayoutKind.Sequential)] struct Configuration
    {
        public uint Type, Start, Error;
        public IntPtr Image, Group;
        public uint Tag;
        public IntPtr Dependencies, Account, DisplayName;
    }
    public sealed class Snapshot
    {
        public uint Type, Start, Error;
        public string Image, Group, Account, DisplayName;
        public string[] Dependencies;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr OpenSCManagerW(string machine, string database, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr OpenServiceW(IntPtr manager, string name, uint access);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool QueryServiceConfigW(IntPtr service, IntPtr buffer, uint size, out uint needed);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ChangeServiceConfigW(IntPtr service, uint type, uint start, uint error, string image, string group, IntPtr tag, string dependencies, string account, string password, string displayName);
    [DllImport("advapi32.dll")] static extern bool CloseServiceHandle(IntPtr handle);
    static string Text(IntPtr value) { return value == IntPtr.Zero ? "" : Marshal.PtrToStringUni(value); }
    static IntPtr Open(string name, uint access, out IntPtr manager)
    {
        manager = OpenSCManagerW(null, null, 1);
        if (manager == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        var service = OpenServiceW(manager, name, access);
        if (service == IntPtr.Zero) { int error = Marshal.GetLastWin32Error(); CloseServiceHandle(manager); manager = IntPtr.Zero; throw new System.ComponentModel.Win32Exception(error); }
        return service;
    }
    public static Snapshot Read(string name)
    {
        IntPtr manager, service = Open(name, 1, out manager), data = IntPtr.Zero;
        try {
            uint needed;
            QueryServiceConfigW(service, IntPtr.Zero, 0, out needed);
            if (needed == 0) throw new System.ComponentModel.Win32Exception();
            data = Marshal.AllocHGlobal((int)needed);
            if (!QueryServiceConfigW(service, data, needed, out needed)) throw new System.ComponentModel.Win32Exception();
            var value = (Configuration)Marshal.PtrToStructure(data, typeof(Configuration));
            var dependencies = new List<string>();
            for (IntPtr p = value.Dependencies; p != IntPtr.Zero;) {
                string item = Marshal.PtrToStringUni(p);
                if (String.IsNullOrEmpty(item)) break;
                dependencies.Add(item);
                p = IntPtr.Add(p, (item.Length + 1) * 2);
            }
            return new Snapshot { Type = value.Type, Start = value.Start, Error = value.Error, Image = Text(value.Image), Group = Text(value.Group), Account = Text(value.Account), DisplayName = Text(value.DisplayName), Dependencies = dependencies.ToArray() };
        }
        finally { if (data != IntPtr.Zero) Marshal.FreeHGlobal(data); CloseServiceHandle(service); CloseServiceHandle(manager); }
    }
    public static void SetNonBootStart(string name, uint start)
    {
        var before = Read(name);
        if (before.Type != 1 || before.Start < 2 || (start != 2 && start != 3)) throw new InvalidOperationException("Refusing boot/system/unsupported service fixture");
        IntPtr manager, service = Open(name, 2, out manager);
        try {
            if (!ChangeServiceConfigW(service, UInt32.MaxValue, start, UInt32.MaxValue, null, null, IntPtr.Zero, null, null, null, null)) throw new System.ComponentModel.Win32Exception();
        }
        finally { CloseServiceHandle(service); CloseServiceHandle(manager); }
    }
}
