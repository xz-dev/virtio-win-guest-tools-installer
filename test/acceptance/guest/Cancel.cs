// Installs an MSI and presses "Cancel" when a chosen action starts, like a user would in the progress dialog.
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class MsiCancel
{
    const uint ActionStart = 0x08000000, IdCancel = 2;
    const uint Filter = (1u << 8) | (1u << 4) | (1u << 1) | (1u << 2) | (1u << 3) | (1u << 10);
    delegate int Handler(IntPtr context, uint type, uint record);
    [DllImport("msi.dll")] static extern uint MsiSetExternalUIRecord(Handler h, uint filter, IntPtr ctx, out IntPtr previous);
    [DllImport("msi.dll", EntryPoint = "MsiSetExternalUIRecord")] static extern uint Restore(IntPtr h, uint filter, IntPtr ctx, out IntPtr previous);
    [DllImport("msi.dll")] static extern uint MsiSetInternalUI(uint level, IntPtr window);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiEnableLogW(uint mode, string path, uint attributes);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiInstallProductW(string package, string properties);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)] static extern uint MsiRecordGetStringW(uint record, uint field, StringBuilder value, ref uint size);

    static string ActionName(uint record)
    {
        uint size = 256;
        var value = new StringBuilder((int)size);
        return MsiRecordGetStringW(record, 1, value, ref size) == 0 ? value.ToString() : "";
    }

    // Returns the msiexec exit code. Cancels once, at the first start of cancelAt after MsiCleanupOnSuccess was seen.
    public static uint Run(string package, string properties, string cancelAt, string log)
    {
        bool cleanupSeen = false, cancelled = false;
        Handler callback = (context, type, record) =>
        {
            if ((type & 0xFF000000) != ActionStart) return 0;
            string action = ActionName(record);
            if (action == "MsiCleanupOnSuccess") cleanupSeen = true;
            if (!cancelled && cleanupSeen && action == cancelAt) { cancelled = true; return (int)IdCancel; }
            return 0;
        };
        uint oldLevel = MsiSetInternalUI(2, IntPtr.Zero);
        IntPtr previous, ignored;
        if (MsiSetExternalUIRecord(callback, Filter, IntPtr.Zero, out previous) != 0) throw new InvalidOperationException("external UI");
        try
        {
            MsiEnableLogW(0x1FFF, log, 2);
            uint code = MsiInstallProductW(package, properties);
            if (!cancelled) throw new InvalidOperationException("action " + cancelAt + " never started; exit " + code);
            return code;
        }
        finally
        {
            Restore(previous, 0, IntPtr.Zero, out ignored);
            MsiSetInternalUI(oldLevel, IntPtr.Zero);
            GC.KeepAlive(callback);
        }
    }
}
