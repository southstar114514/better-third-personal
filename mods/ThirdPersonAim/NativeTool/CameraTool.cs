using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

internal static class CameraTool
{
    const int CameraRva = 0x14fd03;
    const string SupportedHash = "002b36487fec7c98882929fbccdb506d0146bbf3270cbb964a4d21c5edf7eebc";
    static readonly byte[] Original = { 0x48, 0x8b, 0x05, 0x86, 0x0a, 0xae, 0x00 };
    static readonly byte[] Modified = { 0xe9, 0x4b, 0, 0, 0, 0x90, 0x90 };
    const int ReticleGateRva = 0x15efe9;
    const int ReticleShimRva = 0x892e20;
    static readonly byte[] ReticleGateOriginal = { 0x0f, 0x84, 0x62, 0x06, 0, 0 };
    static readonly byte[] ReticleGateModified = { 0xe9, 0x32, 0x3e, 0x73, 0, 0x90 };
    // Preserve first-person and ordinary Pilot behavior; allow Titans and the Charge Rifle.
    // Unused executable section padding in the hash-locked client.dll.
    static readonly byte[] ReticleShim = {
        0x0f, 0x85, 0xc9, 0xc1, 0x8c, 0xff, 0x48, 0x8b, 0xcb, 0xe8, 0x3a, 0x79,
        0xb4, 0xff, 0x84, 0xc0, 0x0f, 0x85, 0xb9, 0xc1, 0x8c, 0xff, 0x48, 0x8b,
        0xcb, 0xe8, 0x82, 0xeb, 0x81, 0xff, 0x48, 0x85, 0xc0, 0x0f, 0x84, 0x0a,
        0xc8, 0x8c, 0xff, 0x48, 0x8b, 0xc8, 0xe8, 0xf1, 0x6a, 0xd1, 0xff, 0x48,
        0x8d, 0x15, 0x24, 0x00, 0x00, 0x00, 0xb9, 0x13, 0x00, 0x00, 0x00, 0x44,
        0x8a, 0x00, 0x44, 0x3a, 0x02, 0x0f, 0x85, 0xea, 0xc7, 0x8c, 0xff, 0x48,
        0xff, 0xc0, 0x48, 0xff, 0xc2, 0xff, 0xc9, 0x0f, 0x85, 0xe6, 0xff, 0xff,
        0xff, 0xe9, 0x75, 0xc1, 0x8c, 0xff, 0x6d, 0x70, 0x5f, 0x77, 0x65, 0x61,
        0x70, 0x6f, 0x6e, 0x5f, 0x64, 0x65, 0x66, 0x65, 0x6e, 0x64, 0x65, 0x72,
        0x00,
    };

    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr handle, IntPtr address, byte[] data, UIntPtr size, out UIntPtr count);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteProcessMemory(IntPtr handle, IntPtr address, byte[] data, UIntPtr size, out UIntPtr count);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool VirtualProtectEx(IntPtr handle, IntPtr address, UIntPtr size, uint protection, out uint old);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FlushInstructionCache(IntPtr handle, IntPtr address, UIntPtr size);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

    static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message + " (Win32 " + Marshal.GetLastWin32Error() + ")");
    }

    static string Hash(string path)
    {
        using (var sha = SHA256.Create())
        using (var stream = File.OpenRead(path))
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
    }

    static ProcessModule WaitForClient(Process process)
    {
        for (int i = 0; i < 300; i++)
        {
            if (process.HasExited) throw new InvalidOperationException("Game exited before client.dll was loaded.");
            process.Refresh();
            foreach (ProcessModule module in process.Modules)
                if (module.ModuleName.Equals("client.dll", StringComparison.OrdinalIgnoreCase)) return module;
            Thread.Sleep(200);
        }
        throw new TimeoutException("client.dll was not loaded within 60 seconds.");
    }

    static void Patch(Process process, bool restore)
    {
        ProcessModule client = WaitForClient(process);
        if (Hash(client.FileName) != SupportedHash)
            throw new InvalidOperationException("Unsupported client.dll version; no memory was changed.");
        IntPtr handle = OpenProcess(0x438, false, process.Id);
        Require(handle != IntPtr.Zero, "OpenProcess failed");
        try
        {
            int[] rvas = { CameraRva, ReticleShimRva, ReticleGateRva };
            byte[][] originals = { Original, new byte[ReticleShim.Length], ReticleGateOriginal };
            byte[][] modified = { Modified, ReticleShim, ReticleGateModified };
            byte[][] before = new byte[rvas.Length][];
            // Validate every site before changing any instruction.
            for (int i = 0; i < rvas.Length; i++)
            {
                before[i] = Read(handle, new IntPtr(client.BaseAddress.ToInt64() + rvas[i]), originals[i].Length);
                if (!before[i].SequenceEqual(originals[i]) && !before[i].SequenceEqual(modified[i]))
                    throw new InvalidOperationException("Instructions differ at RVA 0x" + rvas[i].ToString("x") + "; no memory was changed.");
            }
            // Install the shim before redirecting execution; remove the redirect before the shim.
            for (int step = 0; step < rvas.Length; step++)
            {
                int i = restore ? rvas.Length - 1 - step : step;
                IntPtr address = new IntPtr(client.BaseAddress.ToInt64() + rvas[i]);
                byte[] desired = restore ? originals[i] : modified[i];
                Console.WriteLine("PID={0} RVA=0x{1:x} BEFORE={2}", process.Id, rvas[i], BitConverter.ToString(before[i]));
                Write(handle, address, desired);
                Console.WriteLine("AFTER={0}", BitConverter.ToString(Read(handle, address, desired.Length)));
            }
            Console.WriteLine(restore ? "Camera and native Titan reticle memory restored." : "越肩相机、泰坦及充能步枪原生动态准星补丁已就绪。进入多人游戏，按 6 开关越肩视角。");
        }
        finally { CloseHandle(handle); }
    }

    static byte[] Read(IntPtr handle, IntPtr address, int length)
    {
        UIntPtr count;
        byte[] bytes = new byte[length];
        Require(ReadProcessMemory(handle, address, bytes, new UIntPtr((uint)length), out count) && count.ToUInt64() == (ulong)length, "Read failed");
        return bytes;
    }

    static void Write(IntPtr handle, IntPtr address, byte[] desired)
    {
        UIntPtr size = new UIntPtr((uint)desired.Length), count;
        byte[] before = Read(handle, address, desired.Length);
        if (!before.SequenceEqual(desired))
        {
            uint old;
            Require(VirtualProtectEx(handle, address, size, 0x40, out old), "Protect failed");
            try
            {
                Require(WriteProcessMemory(handle, address, desired, size, out count) && count.ToUInt64() == (ulong)desired.Length, "Write failed");
                Require(FlushInstructionCache(handle, address, size), "Flush failed");
            }
            finally
            {
                uint ignored;
                Require(VirtualProtectEx(handle, address, size, old, out ignored), "Protection restore failed");
            }
        }
        Require(Read(handle, address, desired.Length).SequenceEqual(desired), "Readback failed");
    }

    static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        try
        {
            if (args.Length == 1 && args[0] == "--selftest")
            {
                Require(CameraRva + 5 + BitConverter.ToInt32(Modified, 1) == 0x14fd53, "Jump target mismatch");
                Require(ReticleGateRva + 5 + BitConverter.ToInt32(ReticleGateModified, 1) == ReticleShimRva, "Reticle redirect mismatch");
                Require(ReticleShimRva + 6 + BitConverter.ToInt32(ReticleShim, 2) == 0x15efef, "First-person path mismatch");
                Require(ReticleShimRva + 14 + BitConverter.ToInt32(ReticleShim, 10) == 0x3da768, "IsTitan call mismatch");
                Require(ReticleShimRva + 22 + BitConverter.ToInt32(ReticleShim, 18) == 0x15efef, "Titan path mismatch");
                Require(ReticleShimRva + 30 + BitConverter.ToInt32(ReticleShim, 26) == 0x0b19c0, "Active weapon call mismatch");
                Require(ReticleShimRva + 47 + BitConverter.ToInt32(ReticleShim, 43) == 0x5a9940, "Weapon class call mismatch");
                Require(Encoding.ASCII.GetString(ReticleShim, ReticleShim.Length - 19, 19) == "mp_weapon_defender\0", "Charge Rifle class mismatch");
                Console.WriteLine("SELFTEST PASS: camera, native Titan and Charge Rifle reticles; first-person and ordinary Pilot branches.");
                return 0;
            }
            if (args.Length == 2 && (args[0] == "--attach" || args[0] == "--restore"))
            {
                Patch(Process.GetProcessById(int.Parse(args[1])), args[0] == "--restore");
                return 0;
            }
            DirectoryInfo root = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory);
            while (root != null && !File.Exists(Path.Combine(root.FullName, "NorthstarLauncher.exe"))) root = root.Parent;
            if (root == null) throw new FileNotFoundException("Place this tool inside your Titanfall 2 game directory.");
            string game = root.FullName;
            if (Hash(Path.Combine(game, "bin", "x64_retail", "client.dll")) != SupportedHash)
                throw new InvalidOperationException("Unsupported client.dll version.");
            Process process = Process.Start(new ProcessStartInfo(Path.Combine(game, "NorthstarLauncher.exe")) {
                WorkingDirectory = game, UseShellExecute = false, Arguments = string.Join(" ", args.Select(a => "\"" + a.Replace("\"", "\\\"") + "\""))
            });
            Patch(process, false);
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("TPA ERROR: " + error.Message);
            return 1;
        }
    }
}
