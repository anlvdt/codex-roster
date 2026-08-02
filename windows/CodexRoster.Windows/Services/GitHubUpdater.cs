using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexRoster.Windows.Services;

public sealed class GitHubUpdater
{
    private const string LatestReleaseUrl = "https://api.github.com/repos/anlvdt/codex-roster/releases/latest";
    private const long MaximumArchiveBytes = 128L * 1024 * 1024;
    private const string WindowsAssetName = "Codex-Roster-Windows-x64.zip";
    private static readonly HttpClient HttpClient = CreateHttpClient();

    public sealed record Update(string Version, Uri DownloadUrl, string Digest);

    public async Task<Update?> CheckAsync(string currentVersion, CancellationToken cancellationToken = default)
    {
        using var response = await HttpClient.GetAsync(LatestReleaseUrl, cancellationToken);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException("GitHub không trả về bản phát hành mới nhất.");
        var release = await JsonSerializer.DeserializeAsync<GitHubRelease>(
            await response.Content.ReadAsStreamAsync(cancellationToken),
            cancellationToken: cancellationToken)
            ?? throw new InvalidOperationException("Không thể đọc dữ liệu GitHub Release.");
        if (release.Draft || release.Prerelease) throw new InvalidOperationException("GitHub Release mới nhất chưa ổn định.");
        var asset = release.Assets.FirstOrDefault(asset => string.Equals(asset.Name, WindowsAssetName, StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException("GitHub Release chưa có bundle Windows desktop.");
        if (string.IsNullOrWhiteSpace(asset.Digest) || !asset.Digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Bundle Windows không có SHA-256 do GitHub công bố.");
        }
        var version = release.TagName.Trim().TrimStart('v', 'V');
        return IsNewer(version, currentVersion) ? new Update(version, asset.BrowserDownloadUrl, asset.Digest) : null;
    }

    public async Task<string> DownloadAndStageAsync(Update update, CancellationToken cancellationToken = default)
    {
        using var response = await HttpClient.GetAsync(update.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException("Không thể tải bản cập nhật Windows.");
        if (response.Content.Headers.ContentLength is long contentLength && contentLength > MaximumArchiveBytes)
        {
            throw new InvalidOperationException("Bundle cập nhật vượt giới hạn kích thước an toàn.");
        }

        var root = Path.Combine(Path.GetTempPath(), $"codex-roster-update-{Guid.NewGuid():N}");
        var archive = Path.Combine(root, "update.zip");
        var stage = Path.Combine(root, "stage");
        Directory.CreateDirectory(root);
        try
        {
            await using (var input = await response.Content.ReadAsStreamAsync(cancellationToken))
            await using (var output = new FileStream(archive, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                await CopyWithLimitAsync(input, output, cancellationToken);
            }
            await using var archiveStream = File.OpenRead(archive);
            var digest = "sha256:" + Convert.ToHexString(await SHA256.HashDataAsync(archiveStream, cancellationToken)).ToLowerInvariant();
            if (!string.Equals(digest, update.Digest, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("SHA-256 của bundle tải về không khớp GitHub Release.");
            }

            ExtractSafely(archive, stage);
            var executable = Path.Combine(stage, "CodexRoster.Windows.exe");
            var helperCli = Path.Combine(stage, "codex-roster.exe");
            if (!File.Exists(executable) || !File.Exists(helperCli))
            {
                throw new InvalidOperationException("Bundle cập nhật không chứa đầy đủ desktop app.");
            }
            var stagedVersion = FileVersionInfo.GetVersionInfo(executable).ProductVersion?.Split('+')[0] ?? string.Empty;
            if (!IsSameVersion(stagedVersion, update.Version))
            {
                throw new InvalidOperationException("Phiên bản bundle không khớp GitHub Release.");
            }
            return stage;
        }
        catch
        {
            try { Directory.Delete(root, recursive: true); } catch { }
            throw;
        }
    }

    public void ScheduleInstall(string stageDirectory)
    {
        var installDirectory = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var helper = Path.Combine(Path.GetTempPath(), $"codex-roster-install-{Guid.NewGuid():N}.ps1");
        File.WriteAllText(helper, """
param([int]$AppProcessId, [string]$InstallDirectory, [string]$StageDirectory)
$ErrorActionPreference = 'Stop'
while (Get-Process -Id $AppProcessId -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 150 }
$backupDirectory = "$InstallDirectory.previous"
Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction SilentlyContinue
Move-Item -LiteralPath $InstallDirectory -Destination $backupDirectory
try {
  Move-Item -LiteralPath $StageDirectory -Destination $InstallDirectory
  Start-Process -FilePath (Join-Path $InstallDirectory 'CodexRoster.Windows.exe')
  Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Split-Path $StageDirectory -Parent) -Recurse -Force -ErrorAction SilentlyContinue
} catch {
  Remove-Item -LiteralPath $InstallDirectory -Recurse -Force -ErrorAction SilentlyContinue
  Move-Item -LiteralPath $backupDirectory -Destination $InstallDirectory -ErrorAction SilentlyContinue
  Start-Process -FilePath (Join-Path $InstallDirectory 'CodexRoster.Windows.exe')
  throw
} finally {
  Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}
""");
        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(helper);
        startInfo.ArgumentList.Add(Environment.ProcessId.ToString());
        startInfo.ArgumentList.Add(installDirectory);
        startInfo.ArgumentList.Add(stageDirectory);
        _ = Process.Start(startInfo) ?? throw new InvalidOperationException("Không thể mở trình cài đặt cập nhật.");
    }

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(2) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("codex-roster");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    private static async Task CopyWithLimitAsync(Stream input, Stream output, CancellationToken cancellationToken)
    {
        var buffer = new byte[64 * 1024];
        long copied = 0;
        while (true)
        {
            var read = await input.ReadAsync(buffer, cancellationToken);
            if (read == 0) return;
            copied += read;
            if (copied > MaximumArchiveBytes) throw new InvalidOperationException("Bundle cập nhật vượt giới hạn kích thước an toàn.");
            await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
        }
    }

    private static void ExtractSafely(string archive, string destination)
    {
        var root = Path.GetFullPath(destination) + Path.DirectorySeparatorChar;
        using var zip = ZipFile.OpenRead(archive);
        foreach (var entry in zip.Entries)
        {
            var target = Path.GetFullPath(Path.Combine(destination, entry.FullName));
            if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Bundle cập nhật có đường dẫn không an toàn.");
            }
            if (string.IsNullOrEmpty(entry.Name))
            {
                Directory.CreateDirectory(target);
                continue;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            entry.ExtractToFile(target, overwrite: false);
        }
    }

    private static bool IsNewer(string remote, string current)
    {
        var remoteParts = ParseVersion(remote);
        var currentParts = ParseVersion(current);
        if (remoteParts.Length == 0 || currentParts.Length == 0) return false;
        for (var index = 0; index < Math.Max(remoteParts.Length, currentParts.Length); index++)
        {
            var left = index < remoteParts.Length ? remoteParts[index] : 0;
            var right = index < currentParts.Length ? currentParts[index] : 0;
            if (left != right) return left > right;
        }
        return false;
    }

    private static bool IsSameVersion(string left, string right)
    {
        var leftParts = ParseVersion(left);
        var rightParts = ParseVersion(right);
        if (leftParts.Length == 0 || rightParts.Length == 0 || leftParts.Contains(-1) || rightParts.Contains(-1)) return false;
        for (var index = 0; index < Math.Max(leftParts.Length, rightParts.Length); index++)
        {
            if ((index < leftParts.Length ? leftParts[index] : 0) != (index < rightParts.Length ? rightParts[index] : 0)) return false;
        }
        return true;
    }

    private static int[] ParseVersion(string value) => value.Trim().TrimStart('v', 'V').Split('.')
        .Select(part => int.TryParse(part, out var number) ? number : -1).ToArray();

    private sealed class GitHubRelease
    {
        [JsonPropertyName("tag_name")]
        public string TagName { get; init; } = string.Empty;
        [JsonPropertyName("draft")]
        public bool Draft { get; init; }
        [JsonPropertyName("prerelease")]
        public bool Prerelease { get; init; }
        [JsonPropertyName("assets")]
        public List<GitHubAsset> Assets { get; init; } = [];
    }

    private sealed class GitHubAsset
    {
        [JsonPropertyName("name")]
        public string Name { get; init; } = string.Empty;
        [JsonPropertyName("browser_download_url")]
        public Uri BrowserDownloadUrl { get; init; } = null!;
        [JsonPropertyName("digest")]
        public string? Digest { get; init; }
    }
}
