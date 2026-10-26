#requires -Version 5.1
<#
.SYNOPSIS
Repairs the empty-avcC defect in H.264 MP4 exports from Line/DevLine.
.DESCRIPTION
Standalone Windows PowerShell 5.1 script. No ffmpeg, Python, modules or network.
Creates new *_repaired.mp4 files by default. -InPlace replaces the original only
after a temporary repaired file passes verification. No backup copy is retained.
Checks every video sample before repair, then verifies SHA-256 of every mdat payload.
This is a container repair, not a video decoder or a general-purpose MP4 repair tool.
.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Repair-LineMp4.ps1 -Folder "D:\Video"
.EXAMPLE
.\Repair-LineMp4.ps1 -Folder "D:\Video" -Recurse -CheckOnly
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Folder,
    [switch]$Recurse,
    [switch]$CheckOnly,
    [switch]$InPlace,
    [string]$OutputDirectory,
    [string]$ReportPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Folder)) { $Folder = $PSScriptRoot }
if ($InPlace -and $OutputDirectory) { throw '-InPlace cannot be combined with -OutputDirectory.' }

if (-not ('LineMp4RepairV2.Engine' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Security.Cryptography;

namespace LineMp4RepairV2 {
    public sealed class Result {
        public string Input, Output, Status, Message;
        public long Samples, VideoBytes;
        public string MediaSha256;
    }
    sealed class Unsupported : Exception { public Unsupported(string s) : base(s) {} }
    sealed class Box {
        public string Type;
        public long Pos, Size;
        public int Header;
        public List<Box> Children = new List<Box>();
        public byte[] Replacement;
    }
    sealed class Plan {
        public byte[] Moov;
        public Box Root;
        public List<Box> Media;
        public long Samples, Bytes;
        public int Repairs;
        public bool SawAnnexB;
    }
    sealed class Bits {
        readonly byte[] data;
        int pos;
        public Bits(byte[] nal) {
            List<byte> b = new List<byte>();
            int zeros = 0;
            for (int i = 1; i < nal.Length; i++) {
                byte v = nal[i];
                if (zeros >= 2 && v == 3) { zeros = 0; continue; }
                b.Add(v); zeros = v == 0 ? zeros + 1 : 0;
            }
            data = b.ToArray();
        }
        public uint Read(int n) {
            if (n < 0 || n > 32 || pos + (long)n > data.Length * 8L)
                throw new Unsupported("Truncated SPS.");
            uint v = 0;
            for (int i = 0; i < n; i++, pos++)
                v = (v << 1) | (uint)((data[pos / 8] >> (7 - pos % 8)) & 1);
            return v;
        }
        public uint UE() {
            int n = 0;
            while (Read(1) == 0) if (++n > 30) throw new Unsupported("Invalid SPS Exp-Golomb value.");
            return ((1U << n) - 1) + Read(n);
        }
    }
    public static class Engine {
        const int MaxMoov = 256 * 1024 * 1024;
        const int MaxSample = 64 * 1024 * 1024;
        const int MaxSamples = 10000000;
        static uint U32(byte[] b, int p) {
            if (p < 0 || p > b.Length - 4) throw new InvalidDataException("Truncated MP4 table.");
            return ((uint)b[p] << 24) | ((uint)b[p + 1] << 16) | ((uint)b[p + 2] << 8) | b[p + 3];
        }
        static long U64(byte[] b, int p) {
            ulong v = ((ulong)U32(b, p) << 32) | U32(b, p + 4);
            if (v > long.MaxValue) throw new Unsupported("Offset exceeds Int64.");
            return (long)v;
        }
        static void Put32(byte[] b, int p, uint v) {
            b[p] = (byte)(v >> 24); b[p + 1] = (byte)(v >> 16);
            b[p + 2] = (byte)(v >> 8); b[p + 3] = (byte)v;
        }
        static void Put64(byte[] b, int p, long v) {
            Put32(b, p, (uint)((ulong)v >> 32)); Put32(b, p + 4, (uint)v);
        }
        static byte[] Read(FileStream f, long p, int n) {
            byte[] b = new byte[n]; ReadInto(f, p, b, n); return b;
        }
        static void ReadInto(FileStream f, long p, byte[] b, int n) {
            if (p < 0 || n < 0 || p > f.Length - n) throw new InvalidDataException("Read outside file.");
            f.Position = p; int got = 0;
            while (got < n) {
                int r = f.Read(b, got, n - got);
                if (r == 0) throw new EndOfStreamException();
                got += r;
            }
        }
        static List<Box> Top(FileStream f) {
            List<Box> list = new List<Box>(); long p = 0;
            while (p < f.Length) {
                if (f.Length - p < 8) throw new InvalidDataException("Incomplete top-level atom.");
                byte[] b = Read(f, p, 8); long n = U32(b, 0); int h = 8;
                if (n == 1) { n = U64(Read(f, p + 8, 8), 0); h = 16; }
                if (n == 0) n = f.Length - p;
                if (n < h || n > f.Length - p) throw new InvalidDataException("Invalid top-level atom size.");
                list.Add(new Box { Type = Encoding.ASCII.GetString(b, 4, 4), Pos = p, Size = n, Header = h });
                p += n;
            }
            return list;
        }
        static List<Box> Parse(byte[] b, int start, int end, int depth) {
            if (depth > 16) throw new Unsupported("Atom nesting is too deep.");
            List<Box> list = new List<Box>(); int p = start;
            while (p < end) {
                if (end - p < 8) throw new InvalidDataException("Incomplete moov atom.");
                long n = U32(b, p); int h = 8;
                if (n == 1) { n = U64(b, p + 8); h = 16; }
                if (n == 0) n = end - p;
                if (n < h || n > end - p) throw new InvalidDataException("Invalid moov child size.");
                Box a = new Box { Type = Encoding.ASCII.GetString(b, p + 4, 4), Pos = p, Size = n, Header = h };
                int child = -1;
                if (a.Type == "moov" || a.Type == "trak" || a.Type == "mdia" || a.Type == "minf" || a.Type == "stbl") child = p + h;
                if (a.Type == "stsd") child = p + h + 8;
                if (a.Type == "avc1") child = p + h + 78;
                if (child >= 0) {
                    if (child > p + n) throw new InvalidDataException("Truncated sample entry.");
                    a.Children = Parse(b, child, p + (int)n, depth + 1);
                }
                list.Add(a); p += (int)n;
            }
            return list;
        }
        static Box Find(Box parent, string type, bool required) {
            Box found = null;
            foreach (Box b in parent.Children) if (b.Type == type) {
                if (found != null) throw new Unsupported("Multiple " + type + " atoms are unsupported.");
                found = b;
            }
            if (found == null && required) throw new InvalidDataException("Missing " + type + " atom.");
            return found;
        }
        static int Payload(Box b) { return checked((int)b.Pos + b.Header); }
        static void Need(Box b, long n) {
            if (n < 0 || b.Size - b.Header < n) throw new InvalidDataException("Truncated " + b.Type + " table.");
        }
        static bool Equal(byte[] a, byte[] b) {
            if (a.Length != b.Length) return false;
            for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
            return true;
        }
        static bool Annex(byte[] b, int n) {
            return n >= 4 && b[0] == 0 && b[1] == 0 && (b[2] == 1 || (b[2] == 0 && b[3] == 1));
        }
        static bool Nals(byte[] b, int n, out List<int[]> units) {
            units = new List<int[]>(); int p = 0;
            while (p < n) {
                if (n - p < 4) return false;
                uint len = U32(b, p); p += 4;
                if (len == 0 || len > n - p) return false;
                int type = b[p] & 31;
                if ((b[p] & 128) != 0 || type == 0 || type > 23) return false;
                units.Add(new int[] { p, (int)len }); p += (int)len;
            }
            return units.Count > 0;
        }
        static byte[] Config(byte[] sps, byte[] pps) {
            if (sps == null || pps == null || sps.Length < 5 || sps.Length > 65535 || pps.Length > 65535)
                throw new Unsupported("SPS/PPS not found or invalid.");
            int profile = sps[1]; byte[] ext = new byte[0];
            if (profile == 100 || profile == 110 || profile == 122 || profile == 144) {
                Bits bits = new Bits(sps); bits.Read(24); bits.UE();
                uint chroma = bits.UE();
                if (chroma > 3) throw new Unsupported("Invalid SPS chroma format.");
                if (chroma == 3) bits.Read(1);
                uint luma = bits.UE(), color = bits.UE();
                if (luma > 7 || color > 7) throw new Unsupported("Unsupported SPS bit depth.");
                ext = new byte[] { (byte)(252 | chroma), (byte)(248 | luma), (byte)(248 | color), 0 };
            } else if (profile != 66 && profile != 77 && profile != 88)
                throw new Unsupported("Unsupported H.264 profile: " + profile);
            using (MemoryStream m = new MemoryStream()) {
                m.Write(new byte[] { 1, sps[1], sps[2], sps[3], 255, 225, (byte)(sps.Length >> 8), (byte)sps.Length }, 0, 8);
                m.Write(sps, 0, sps.Length); m.WriteByte(1);
                m.WriteByte((byte)(pps.Length >> 8)); m.WriteByte((byte)pps.Length);
                m.Write(pps, 0, pps.Length); m.Write(ext, 0, ext.Length); return m.ToArray();
            }
        }
        static bool InMedia(List<Box> media, long p, long n) {
            foreach (Box b in media)
                if (p >= b.Pos + b.Header && p <= b.Pos + b.Size && n <= b.Pos + b.Size - p) return true;
            return false;
        }
        static void InspectTrack(FileStream f, Plan plan, Box stbl, Box entry, Box avcc) {
            byte[] b = plan.Moov;
            int ep = Payload(entry);
            if (b[ep + 6] != 0 || b[ep + 7] != 1) throw new Unsupported("External data references are unsupported.");
            Box sz = Find(stbl, "stsz", true), sc = Find(stbl, "stsc", true);
            Box co = Find(stbl, "stco", false), co64 = Find(stbl, "co64", false);
            if ((co == null) == (co64 == null)) throw new Unsupported("Expected exactly one stco/co64 table.");
            if (co == null) co = co64;
            Need(sz, 12); Need(sc, 8); Need(co, 8);
            int sp = Payload(sz), cp = Payload(co), rp = Payload(sc);
            uint fixedSize = U32(b, sp + 4), count = U32(b, sp + 8);
            uint chunks = U32(b, cp + 4), runs = U32(b, rp + 4);
            if (count == 0 || count > MaxSamples || chunks == 0 || chunks > count || runs == 0 || runs > chunks)
                throw new Unsupported("Empty, excessively large or inconsistent sample tables.");
            if (fixedSize == 0) Need(sz, 12L + 4L * count);
            Need(co, 8L + (co.Type == "co64" ? 8L : 4L) * chunks); Need(sc, 8L + 12L * runs);
            for (uint k = 0; k < runs; k++) {
                int q = rp + 8 + (int)k * 12;
                uint first = U32(b, q);
                if ((k == 0 && first != 1) || first > chunks || (k > 0 && first <= U32(b, q - 12)) || U32(b, q + 4) == 0 || U32(b, q + 8) != 1)
                    throw new Unsupported("Unsupported stsc mapping or sample description switch.");
            }
            byte[] buffer = new byte[65536], sps = null, pps = null;
            uint sample = 0, run = 0; bool slice = false;
            for (uint chunk = 1; chunk <= chunks; chunk++) {
                while (run + 1 < runs && chunk >= U32(b, rp + 8 + (int)(run + 1) * 12)) run++;
                uint perChunk = U32(b, rp + 12 + (int)run * 12);
                int offsetIndex = cp + 8 + (int)(chunk - 1) * (co.Type == "co64" ? 8 : 4);
                long offset = co.Type == "co64" ? U64(b, offsetIndex) : U32(b, offsetIndex);
                if (perChunk > count - sample) throw new InvalidDataException("stsc exceeds sample count.");
                for (uint j = 0; j < perChunk; j++, sample++) {
                    uint n = fixedSize != 0 ? fixedSize : U32(b, sp + 12 + (int)sample * 4);
                    if (n == 0 || n > MaxSample) throw new Unsupported("Zero-size or oversized video sample.");
                    if (!InMedia(plan.Media, offset, n)) throw new InvalidDataException("Sample points outside mdat.");
                    if (buffer.Length < n) buffer = new byte[(int)n];
                    ReadInto(f, offset, buffer, (int)n);
                    List<int[]> units;
                    if (!Nals(buffer, (int)n, out units)) {
                        if (sample == 0 && Annex(buffer, (int)n)) { plan.SawAnnexB = true; return; }
                        throw new Unsupported("Sample " + sample + " is not valid length-prefixed H.264 (4-byte lengths).");
                    }
                    foreach (int[] u in units) {
                        int type = buffer[u[0]] & 31;
                        if (type == 7 || type == 8) {
                            byte[] value = new byte[u[1]]; Buffer.BlockCopy(buffer, u[0], value, 0, value.Length);
                            byte[] previous = type == 7 ? sps : pps;
                            if (previous != null && !Equal(previous, value))
                                throw new Unsupported("SPS/PPS changes inside the file; automatic repair refused.");
                            if (type == 7) sps = value; else pps = value;
                        }
                        if (type == 1 || type == 5) slice = true;
                    }
                    if (sample == 0 && (sps == null || pps == null))
                        throw new Unsupported("First sample does not contain both SPS and PPS.");
                    plan.Bytes += n; offset += n;
                }
            }
            if (sample != count || !slice) throw new InvalidDataException("Sample count mismatch or no H.264 slices.");
            avcc.Replacement = Config(sps, pps); plan.Samples += sample; plan.Repairs++;
        }
        static Plan Analyze(FileStream f) {
            List<Box> top = Top(f), media = new List<Box>(); Box moov = null;
            foreach (Box a in top) {
                if (a.Type == "moof" || a.Type == "sidx" || a.Type == "mfra") throw new Unsupported("Fragmented/indexed MP4 is unsupported.");
                if (a.Type == "mdat") media.Add(a);
                if (a.Type == "moov") { if (moov != null) throw new Unsupported("Multiple moov atoms."); moov = a; }
            }
            if (moov == null || media.Count == 0) throw new InvalidDataException("Missing moov or mdat.");
            if (moov.Size > MaxMoov) throw new Unsupported("moov exceeds the 256 MiB safety limit.");
            byte[] bytes = Read(f, moov.Pos, (int)moov.Size);
            Box root = Parse(bytes, 0, bytes.Length, 0)[0];
            Plan plan = new Plan { Root = root, Moov = bytes, Media = media };
            if (Find(root, "mvex", false) != null) throw new Unsupported("Fragmented MP4 is unsupported.");
            foreach (Box track in root.Children) if (track.Type == "trak") {
                Box mdia = Find(track, "mdia", true), hdlr = Find(mdia, "hdlr", true);
                Need(hdlr, 12);
                if (Encoding.ASCII.GetString(bytes, Payload(hdlr) + 8, 4) != "vide") continue;
                Box stbl = Find(Find(mdia, "minf", true), "stbl", true), stsd = Find(stbl, "stsd", true);
                Need(stsd, 8);
                if (U32(bytes, Payload(stsd) + 4) != stsd.Children.Count) throw new InvalidDataException("stsd entry count mismatch.");
                bool target = false;
                foreach (Box entry in stsd.Children) if (entry.Type == "avc1") {
                    Box avcc = Find(entry, "avcC", false);
                    if (avcc != null && avcc.Size == avcc.Header) target = true;
                }
                if (!target) continue;
                if (stsd.Children.Count != 1) throw new Unsupported("Multiple video sample descriptions.");
                Box e = stsd.Children[0];
                InspectTrack(f, plan, stbl, e, Find(e, "avcC", true));
            }
            // The caller uses the absolute original position when writing.
            root.Pos = 0;
            return plan;
        }
        static byte[] Build(byte[] original, Box a) {
            int start = (int)a.Pos;
            using (MemoryStream m = new MemoryStream()) {
                m.Write(original, start, a.Header);
                if (a.Replacement != null) m.Write(a.Replacement, 0, a.Replacement.Length);
                else if (a.Children.Count == 0) m.Write(original, start + a.Header, (int)a.Size - a.Header);
                else {
                    int p = start + a.Header;
                    foreach (Box child in a.Children) {
                        m.Write(original, p, (int)child.Pos - p);
                        byte[] childBytes = Build(original, child); m.Write(childBytes, 0, childBytes.Length);
                        p = (int)(child.Pos + child.Size);
                    }
                    m.Write(original, p, start + (int)a.Size - p);
                }
                byte[] result = m.ToArray();
                if (a.Header == 16) { Put32(result, 0, 1); Put64(result, 8, result.Length); }
                else Put32(result, 0, (uint)result.Length);
                return result;
            }
        }
        static void CopyRange(FileStream source, FileStream dest, long start, long count) {
            source.Position = start; byte[] b = new byte[4 * 1024 * 1024];
            while (count > 0) {
                int n = source.Read(b, 0, (int)Math.Min(count, b.Length));
                if (n == 0) throw new EndOfStreamException();
                dest.Write(b, 0, n); count -= n;
            }
        }
        static string HashMedia(FileStream f, List<Box> media) {
            using (SHA256 sha = SHA256.Create()) {
                byte[] b = new byte[4 * 1024 * 1024];
                foreach (Box a in media) {
                    f.Position = a.Pos + a.Header; long left = a.Size - a.Header;
                    while (left > 0) {
                        int n = f.Read(b, 0, (int)Math.Min(left, b.Length));
                        if (n == 0) throw new EndOfStreamException();
                        sha.TransformBlock(b, 0, n, b, 0); left -= n;
                    }
                }
                sha.TransformFinalBlock(new byte[0], 0, 0);
                return BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
            }
        }
        public static Result Process(string input, string output, bool checkOnly, bool inPlace) {
            Result r = new Result { Input = input, Output = "", MediaSha256 = "" }; string temp = null;
            if (inPlace) output = input;
            try {
                // Deny writers. In-place mode permits atomic replacement while this
                // read handle still locks the original file against modification.
                FileShare share = inPlace ? FileShare.Read | FileShare.Delete : FileShare.Read;
                using (FileStream source = new FileStream(input, FileMode.Open, FileAccess.Read, share)) {
                    Plan p = Analyze(source); r.Samples = p.Samples; r.VideoBytes = p.Bytes;
                    if (p.Repairs == 0) {
                        r.Status = p.SawAnnexB ? "AnnexBUnchanged" : "NoTargetDefect";
                        r.Message = p.SawAnnexB ? "Empty avcC with Annex B; this repair does not apply. Original unchanged." : "No supported empty-avcC defect found. Not a full decoding check.";
                        return r;
                    }
                    if (p.SawAnnexB) throw new Unsupported("Mixed Annex B and AVC tracks with empty avcC.");
                    r.Output = output;
                    if (checkOnly) { r.Status = "WouldRepair"; r.Message = inPlace ? "Validated every video sample; would replace the original after verification." : "Validated every video sample; can reconstruct avcC from SPS/PPS."; return r; }
                    if (!inPlace && (File.Exists(output) || Directory.Exists(output))) {
                        r.Status = "OutputExists"; r.Message = "Existing output was not overwritten or verified."; return r;
                    }
                    byte[] repaired = Build(p.Moov, p.Root);
                    Box originalMoov = null;
                    foreach (Box a in Top(source)) if (a.Type == "moov") originalMoov = a;
                    Directory.CreateDirectory(Path.GetDirectoryName(output));
                    temp = output + "." + Guid.NewGuid().ToString("N") + ".partial";
                    string expectedHash = HashMedia(source, p.Media);
                    using (FileStream dest = new FileStream(temp, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None)) {
                        if (originalMoov.Pos + originalMoov.Size == source.Length) {
                            CopyRange(source, dest, 0, originalMoov.Pos);
                            dest.Write(repaired, 0, repaired.Length);
                        } else {
                            // Keep all mdat offsets unchanged even when moov was at the front.
                            // Retire old moov as free space and append the replacement.
                            CopyRange(source, dest, 0, source.Length);
                            dest.Position = originalMoov.Pos + 4;
                            byte[] free = Encoding.ASCII.GetBytes("free"); dest.Write(free, 0, 4);
                            // A top-level size=0 atom extends to EOF: give it an explicit size before appending.
                            foreach (Box a in Top(source)) {
                                byte[] header = Read(source, a.Pos, 4);
                                if (U32(header, 0) == 0) {
                                    if (a.Size > uint.MaxValue) throw new Unsupported("Cannot append after a >4 GiB size=0 atom.");
                                    Put32(header, 0, (uint)a.Size); dest.Position = a.Pos; dest.Write(header, 0, 4);
                                }
                            }
                            dest.Position = dest.Length; dest.Write(repaired, 0, repaired.Length);
                        }
                        dest.Flush(true);
                        // Reparse container before publishing and verify every mdat payload byte.
                        Plan checkedPlan = Analyze(dest);
                        if (checkedPlan.Repairs != 0) throw new InvalidDataException("Output still has the target defect.");
                        string actualHash = HashMedia(dest, checkedPlan.Media);
                        if (expectedHash != actualHash) throw new InvalidDataException("Media SHA-256 verification failed.");
                        r.MediaSha256 = actualHash;
                    }
                    if (inPlace) File.Replace(temp, input, null);
                    else File.Move(temp, output);
                    temp = null;
                    r.Status = inPlace ? "RepairedInPlace" : "Repaired";
                    r.Message = inPlace ? "Original replaced after media SHA-256 verification. No backup retained; no re-encoding." : "avcC restored; media SHA-256 verified; original timestamps retained. No re-encoding.";
                }
            } catch (Unsupported ex) { r.Status = "Unsupported"; r.Message = ex.Message; }
              catch (Exception ex) { r.Status = "Error"; r.Message = ex.Message; }
            finally { if (temp != null) { try { File.Delete(temp); } catch {} } }
            return r;
        }
    }
}
'@
}

$rootItem = Get-Item -LiteralPath $Folder
if (-not $rootItem.PSIsContainer -or $rootItem.PSProvider.Name -ne 'FileSystem') {
    throw 'Folder must be an existing filesystem directory.'
}
$scanRoot = $rootItem.FullName
$scanPrefix = $scanRoot.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
$outputRoot = $null
if ($OutputDirectory) { $outputRoot = [IO.Path]::GetFullPath($OutputDirectory) }
if (-not $ReportPath) {
    $ReportPath = Join-Path $scanRoot ('Repair-Mp4-report-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
}
$reportFull = [IO.Path]::GetFullPath($ReportPath)
if ([IO.Path]::GetExtension($reportFull) -ine '.csv') { throw 'ReportPath must have a .csv extension.' }
if (Test-Path -LiteralPath $reportFull) { throw "Report already exists: $reportFull" }
if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($reportFull)) -PathType Container)) {
    throw 'The report directory must already exist.'
}
# Open the report before doing any work; refuse overwrite even if another instance races us.
$reportStream = [IO.File]::Open($reportFull, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
$reportWriter = New-Object IO.StreamWriter($reportStream, (New-Object Text.UTF8Encoding($true)))
$reportWriter.AutoFlush = $true
$wroteHeader = $false
$hadErrors = $false
$unresolved = $false
$results = New-Object 'System.Collections.Generic.List[object]'
try {
    $files = @(Get-ChildItem -LiteralPath $scanRoot -File -Recurse:$Recurse | Where-Object {
        $_.Extension -ieq '.mp4' -and $_.BaseName -notmatch '(?i)_repaired$'
    } | Sort-Object FullName)
    Write-Host ('MP4 files: {0}. Mode: {1}' -f $files.Count, $(if ($CheckOnly) { 'CHECK ONLY' } elseif ($InPlace) { 'REPLACE ORIGINALS' } else { 'REPAIR COPIES' }))
    for ($i = 0; $i -lt $files.Count; $i++) {
        $item = $files[$i]
        Write-Host ('[{0}/{1}] {2}' -f ($i + 1), $files.Count, $item.FullName)
        $destDir = $item.DirectoryName
        if ($outputRoot) {
            $relative = $item.FullName.Substring($scanPrefix.Length)
            $relativeDir = [IO.Path]::GetDirectoryName($relative)
            $destDir = $outputRoot
            if ($relativeDir) { $destDir = Join-Path $outputRoot $relativeDir }
        }
        $dest = Join-Path $destDir ($item.BaseName + '_repaired.mp4')
        if ($InPlace) { $dest = $item.FullName }
        $result = [LineMp4RepairV2.Engine]::Process($item.FullName, $dest, [bool]$CheckOnly, [bool]$InPlace)
        $record = [pscustomobject][ordered]@{
            Input = $result.Input; Status = $result.Status; Message = $result.Message
            Output = $result.Output; SamplesChecked = $result.Samples
            VideoBytesChecked = $result.VideoBytes; MediaSha256 = $result.MediaSha256
        }
        $results.Add($record)
        $csvLines = @($record | ConvertTo-Csv -NoTypeInformation)
        if (-not $wroteHeader) { $reportWriter.WriteLine($csvLines[0]); $wroteHeader = $true }
        $reportWriter.WriteLine($csvLines[1])
        Write-Host ('  {0}: {1}' -f $result.Status, $result.Message)
        if ($result.Status -eq 'Error') { $hadErrors = $true }
        if ($result.Status -eq 'Unsupported' -or $result.Status -eq 'OutputExists') { $unresolved = $true }
    }
    if (-not $wroteHeader) {
        $reportWriter.WriteLine('"Input","Status","Message","Output","SamplesChecked","VideoBytesChecked","MediaSha256"')
    }
} finally { $reportWriter.Dispose() }

Write-Host ''
$results | Group-Object Status | ForEach-Object { Write-Host ('{0}: {1}' -f $_.Name, $_.Count) }
Write-Host ('Report: ' + $reportFull)
if ($hadErrors) { exit 1 }
if ($unresolved) { exit 2 }
exit 0
