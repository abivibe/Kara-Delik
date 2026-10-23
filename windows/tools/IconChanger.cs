using System;
using System.IO;
using System.Runtime.InteropServices;

class IconChanger {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr BeginUpdateResource(string pFileName, bool bDeleteExistingResources);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool UpdateResource(IntPtr hUpdate, IntPtr lpType, IntPtr lpName, ushort wLanguage, byte[] lpData, uint cbData);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool EndUpdateResource(IntPtr hUpdate, bool fDiscard);

    static int Main(string[] args) {
        if (args.Length < 2) {
            Console.WriteLine("Usage: IconChanger <exePath> <icoPath>");
            return 1;
        }

        string exePath = args[0];
        string icoPath = args[1];

        if (!File.Exists(exePath) || !File.Exists(icoPath)) {
            Console.WriteLine("File not found!");
            return 1;
        }

        byte[] icoBytes = File.ReadAllBytes(icoPath);
        if (icoBytes.Length < 6) return 1;

        ushort iconCount = BitConverter.ToUInt16(icoBytes, 4);
        Console.WriteLine("ICO contains " + iconCount + " icons.");

        // Prepare GRPICONDIR
        int grpSize = 6 + (iconCount * 14);
        byte[] grpBytes = new byte[grpSize];
        Array.Copy(icoBytes, 0, grpBytes, 0, 6); // header

        IntPtr hUpdate = BeginUpdateResource(exePath, false);
        if (hUpdate == IntPtr.Zero) {
            Console.WriteLine("BeginUpdateResource failed: " + Marshal.GetLastWin32Error());
            return 1;
        }

        try {
            for (int i = 0; i < iconCount; i++) {
                int entryOffset = 6 + (i * 16);
                int grpEntryOffset = 6 + (i * 14);

                // Copy first 12 bytes: width, height, colors, reserved, planes, bitcount, bytesInRes
                Array.Copy(icoBytes, entryOffset, grpBytes, grpEntryOffset, 12);
                
                // Set nID (1-based index)
                ushort iconId = (ushort)(i + 1);
                byte[] idBytes = BitConverter.GetBytes(iconId);
                grpBytes[grpEntryOffset + 12] = idBytes[0];
                grpBytes[grpEntryOffset + 13] = idBytes[1];

                uint bytesInRes = BitConverter.ToUInt32(icoBytes, entryOffset + 8);
                uint imageOffset = BitConverter.ToUInt32(icoBytes, entryOffset + 12);

                byte[] imgBytes = new byte[bytesInRes];
                Array.Copy(icoBytes, imageOffset, imgBytes, 0, bytesInRes);

                // Update RT_ICON (3)
                if (!UpdateResource(hUpdate, (IntPtr)3, (IntPtr)iconId, 0, imgBytes, bytesInRes)) {
                    Console.WriteLine("UpdateResource RT_ICON failed for id " + iconId + ": " + Marshal.GetLastWin32Error());
                    EndUpdateResource(hUpdate, true);
                    return 1;
                }
            }

            // Update RT_GROUP_ICON (14) with ID 1
            // 7z.sfx uses ID 1 or "ICON" or 101, but standard primary group icon ID 1 or 101 is recognized by Explorer
            if (!UpdateResource(hUpdate, (IntPtr)14, (IntPtr)1, 0, grpBytes, (uint)grpBytes.Length)) {
                Console.WriteLine("UpdateResource RT_GROUP_ICON failed: " + Marshal.GetLastWin32Error());
                EndUpdateResource(hUpdate, true);
                return 1;
            }

            // Also update with ID 101 (7z.sfx standard icon ID)
            UpdateResource(hUpdate, (IntPtr)14, (IntPtr)101, 0, grpBytes, (uint)grpBytes.Length);

            if (!EndUpdateResource(hUpdate, false)) {
                Console.WriteLine("EndUpdateResource failed: " + Marshal.GetLastWin32Error());
                return 1;
            }

            Console.WriteLine("Successfully updated icon in " + exePath);
            return 0;
        } catch (Exception ex) {
            Console.WriteLine("Exception: " + ex);
            EndUpdateResource(hUpdate, true);
            return 1;
        }
    }
}
