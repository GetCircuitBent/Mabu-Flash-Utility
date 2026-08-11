// MabuFlashSetup.cs
//
// The single file a user downloads. Double-click it and the Mabu Flash GUI comes
// up; everything else is handled here.
//
// What it does
//   1. Runs as the interactive user (asInvoker manifest) and resolves that
//      user's %LOCALAPPDATA%\MabuFlash as the install root.
//   2. Asks the GitHub Releases API for the newest payload, downloads it, and
//      verifies it against the .sha256 sidecar published beside it.
//   3. Extracts to %LOCALAPPDATA%\MabuFlash\<tag>\ and drops a .complete marker,
//      so later launches skip straight to step 4.
//   4. Re-launches ITSELF elevated, passing the resolved path as an argument,
//      and that instance starts the GUI.
//
// Why re-launch instead of just requesting admin up front: the flash needs
// Administrator, but if the signed-in user is not a local admin then UAC elevates
// into a DIFFERENT account with a DIFFERENT %LOCALAPPDATA%. Resolving the path
// while un-elevated and passing it across means the elevated instance never has
// to guess. That is the same trap the flasher hit with adb.
//
// Why not ps2exe: this is a plain .NET Framework binary built with the csc.exe
// that ships with Windows. No SDK, no PSGallery module, and it avoids the
// heuristic-detection category that ps2exe output falls into.
//
// Offline behaviour: if the API cannot be reached but a completed install already
// exists locally, the newest local one is launched instead of failing.

using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

internal static class MabuFlashSetup
{
    private const string ApiLatest =
        "https://api.github.com/repos/GetCircuitBent/Mabu-Flash-Utility/releases/latest";
    private const string UserAgent = "MabuFlashSetup";
    private const string AppName   = "MabuFlash";

    [STAThread]
    private static int Main(string[] args)
    {
        Application.EnableVisualStyles();

        // Phase 2: already elevated, payload path handed to us. Just launch.
        if (args.Length >= 2 && args[0] == "--run")
        {
            return LaunchGui(args[1]);
        }

        try
        {
            return Phase1();
        }
        catch (Exception ex)
        {
            Fail("Setup failed.\r\n\r\n" + ex.Message);
            return 1;
        }
    }

    // -----------------------------------------------------------------------
    // Phase 1 (un-elevated): resolve, fetch, verify, extract, then re-launch.
    // -----------------------------------------------------------------------
    private static int Phase1()
    {
        // TLS 1.2 is not the default for .NET Framework on stock Windows 10
        // (it negotiates Ssl3|Tls), and both api.github.com and the release CDN
        // refuse anything older.
        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;

        string installRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName);
        Directory.CreateDirectory(installRoot);

        var ui = new ProgressWindow();
        ui.Show();
        ui.Say("Checking for the latest release...");
        Application.DoEvents();

        Release rel = null;
        string relError = null;
        try { rel = QueryLatestRelease(); }
        catch (Exception ex) { relError = ex.Message; }

        string target;

        if (rel == null)
        {
            // Offline or the API is unreachable: fall back to the newest completed
            // local install rather than dead-ending a user who already has one.
            target = NewestCompleteInstall(installRoot);
            if (target == null)
            {
                ui.Close();
                Fail("Could not reach GitHub to download the Mabu Flash payload, and no " +
                     "previous install was found on this PC.\r\n\r\n" +
                     "Connect to the internet and run this again.\r\n\r\nDetail: " + relError);
                return 1;
            }
            ui.Say("Offline - using the copy already installed.");
        }
        else
        {
            target = Path.Combine(installRoot, SafeName(rel.Tag));
            if (!IsComplete(target))
            {
                string zip = Path.Combine(Path.GetTempPath(),
                    AppName + "-payload-" + SafeName(rel.Tag) + ".zip");

                ui.Say("Downloading " + rel.AssetName + " ...");
                Download(rel.ZipUrl, zip, ui);

                ui.Say("Verifying...");
                Application.DoEvents();
                string expected = FetchExpectedHash(rel.ShaUrl);
                string actual   = Sha256File(zip);
                if (!string.Equals(expected, actual, StringComparison.OrdinalIgnoreCase))
                {
                    TryDelete(zip);
                    ui.Close();
                    Fail("The downloaded payload failed its integrity check and was deleted.\r\n\r\n" +
                         "Expected: " + expected + "\r\nGot:      " + actual + "\r\n\r\n" +
                         "Try again; if it keeps failing, something is altering the download.");
                    return 1;
                }

                ui.Say("Installing...");
                Application.DoEvents();
                // Extract to a scratch dir and swap into place, so an interrupted
                // run can never leave a half-populated folder that IsComplete()
                // would later be asked about.
                string staging = target + ".partial";
                if (Directory.Exists(staging)) Directory.Delete(staging, true);
                ZipFile.ExtractToDirectory(zip, staging);
                if (Directory.Exists(target)) Directory.Delete(target, true);
                Directory.Move(staging, target);
                File.WriteAllText(Path.Combine(target, ".complete"), rel.Tag);
                TryDelete(zip);
            }
            else
            {
                ui.Say("Already up to date.");
            }
        }

        ui.Say("Starting Mabu Flash...");
        Application.DoEvents();
        Thread.Sleep(300);
        ui.Close();

        // Re-launch elevated with the path we resolved as THIS user. UAC shows
        // this program's name, which is why the download happens first: the user
        // sees what they are approving, and approves it once.
        var psi = new ProcessStartInfo
        {
            FileName        = Application.ExecutablePath,
            Arguments       = "--run \"" + target + "\"",
            UseShellExecute = true,
            Verb            = "runas"
        };
        try
        {
            Process.Start(psi);
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // 1223 = user cancelled the UAC prompt. Not an error worth a stack trace.
            Fail("Mabu Flash needs Administrator to bind USB drivers and write to the " +
                 "tablet.\r\n\r\nRun it again and choose Yes at the prompt.");
            return 1;
        }
        return 0;
    }

    // -----------------------------------------------------------------------
    // Phase 2 (elevated): start the GUI against the extracted payload.
    // -----------------------------------------------------------------------
    private static int LaunchGui(string root)
    {
        string gui = Path.Combine(root, @"app\MabuFlashGui.ps1");
        if (!File.Exists(gui))
        {
            Fail("The Mabu Flash install looks incomplete - missing:\r\n" + gui +
                 "\r\n\r\nDelete this folder and run setup again:\r\n" + root);
            return 1;
        }

        // CreateNoWindow + UseShellExecute=false so no console flashes up. We are
        // already elevated, so the child inherits it without a second prompt.
        var psi = new ProcessStartInfo
        {
            FileName  = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + gui + "\"",
            UseShellExecute = false,
            CreateNoWindow  = true,
            WorkingDirectory = root
        };
        try
        {
            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            Fail("Could not start the Mabu Flash GUI.\r\n\r\n" + ex.Message);
            return 1;
        }
    }

    // -----------------------------------------------------------------------
    // Release discovery
    // -----------------------------------------------------------------------
    private sealed class Release
    {
        public string Tag;
        public string AssetName;
        public string ZipUrl;
        public string ShaUrl;
    }

    private static Release QueryLatestRelease()
    {
        string json;
        using (var wc = new WebClient())
        {
            wc.Headers.Add("User-Agent", UserAgent);   // GitHub rejects requests without one
            wc.Headers.Add("Accept", "application/vnd.github+json");
            json = wc.DownloadString(ApiLatest);
        }

        var rel = new Release();
        var tag = Regex.Match(json, "\"tag_name\"\\s*:\\s*\"([^\"]+)\"");
        if (!tag.Success) throw new Exception("Could not read tag_name from the GitHub API response.");
        rel.Tag = tag.Groups[1].Value;

        // Match the payload asset and its sidecar by name, so unrelated release
        // assets (an exe, notes, whatever) cannot be picked up by accident.
        foreach (Match m in Regex.Matches(json, "\"browser_download_url\"\\s*:\\s*\"([^\"]+)\""))
        {
            string url  = m.Groups[1].Value;
            string name = url.Substring(url.LastIndexOf('/') + 1);
            if (name.StartsWith("mabuflash-payload-", StringComparison.OrdinalIgnoreCase))
            {
                if (name.EndsWith(".zip.sha256", StringComparison.OrdinalIgnoreCase)) rel.ShaUrl = url;
                else if (name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
                {
                    rel.ZipUrl = url;
                    rel.AssetName = name;
                }
            }
        }
        if (rel.ZipUrl == null) throw new Exception("Release " + rel.Tag + " has no mabuflash-payload-*.zip asset.");
        if (rel.ShaUrl == null) throw new Exception("Release " + rel.Tag + " has no .sha256 sidecar; refusing to install unverified bytes.");
        return rel;
    }

    private static string FetchExpectedHash(string url)
    {
        using (var wc = new WebClient())
        {
            wc.Headers.Add("User-Agent", UserAgent);
            string text = wc.DownloadString(url).Trim();
            // "<hash>  <filename>" (sha256sum format) or a bare hash.
            string first = text.Split(new[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)[0];
            if (!Regex.IsMatch(first, "^[0-9a-fA-F]{64}$"))
                throw new Exception("The .sha256 sidecar did not contain a SHA-256 hash.");
            return first.ToLowerInvariant();
        }
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    private static void Download(string url, string dest, ProgressWindow ui)
    {
        TryDelete(dest);
        using (var wc = new WebClient())
        {
            wc.Headers.Add("User-Agent", UserAgent);
            bool done = false;
            Exception error = null;

            wc.DownloadProgressChanged += (s, e) => ui.Progress(e.ProgressPercentage, e.BytesReceived, e.TotalBytesToReceive);
            wc.DownloadFileCompleted   += (s, e) => { error = e.Error; done = true; };
            wc.DownloadFileAsync(new Uri(url), dest);

            while (!done) { Application.DoEvents(); Thread.Sleep(30); }
            if (error != null) { TryDelete(dest); throw error; }
        }
        ui.Progress(100, 0, 0);
    }

    private static string Sha256File(string path)
    {
        using (var sha = SHA256.Create())
        using (var fs = File.OpenRead(path))
            return BitConverter.ToString(sha.ComputeHash(fs)).Replace("-", "").ToLowerInvariant();
    }

    private static bool IsComplete(string dir)
    {
        return Directory.Exists(dir)
            && File.Exists(Path.Combine(dir, ".complete"))
            && File.Exists(Path.Combine(dir, @"app\MabuFlashGui.ps1"));
    }

    private static string NewestCompleteInstall(string installRoot)
    {
        if (!Directory.Exists(installRoot)) return null;
        return Directory.GetDirectories(installRoot)
            .Where(IsComplete)
            .OrderByDescending(d => Directory.GetLastWriteTimeUtc(d))
            .FirstOrDefault();
    }

    // Release tags become directory names, so strip anything a path cannot hold.
    private static string SafeName(string s)
    {
        foreach (char c in Path.GetInvalidFileNameChars()) s = s.Replace(c, '-');
        return s;
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    private static void Fail(string message)
    {
        MessageBox.Show(message, "Mabu Flash Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    // -----------------------------------------------------------------------
    // Minimal progress window. An 89 MB download with no feedback reads as a
    // hang, and a hung installer is one users kill halfway through.
    // -----------------------------------------------------------------------
    private sealed class ProgressWindow : Form
    {
        private readonly Label _label = new Label();
        private readonly ProgressBar _bar = new ProgressBar();

        public ProgressWindow()
        {
            Text            = "Mabu Flash Setup";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition   = FormStartPosition.CenterScreen;
            MaximizeBox     = false;
            MinimizeBox     = false;
            ControlBox      = false;
            ClientSize      = new Size(440, 110);

            _label.SetBounds(16, 18, 408, 40);
            _label.Text = "Starting...";

            _bar.SetBounds(16, 64, 408, 22);
            _bar.Minimum = 0;
            _bar.Maximum = 100;

            Controls.Add(_label);
            Controls.Add(_bar);
        }

        public void Say(string text)
        {
            _label.Text = text;
            _label.Refresh();
        }

        public void Progress(int percent, long received, long total)
        {
            _bar.Value = Math.Max(0, Math.Min(100, percent));
            if (total > 0)
            {
                _label.Text = string.Format(CultureInfo.InvariantCulture,
                    "Downloading... {0:N0} MB of {1:N0} MB", received / 1048576, total / 1048576);
            }
            _label.Refresh();
            _bar.Refresh();
        }
    }
}
