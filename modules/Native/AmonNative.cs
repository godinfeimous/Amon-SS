// Amon SS - código nativo de apoyo (C# 5, compatible con Windows PowerShell 5.1 y PowerShell 7).
//
//   PatternMatcher : búsqueda multi-patrón Aho-Corasick sobre bytes (firmas de clientes).
//   Compression    : descompresión de Prefetch "MAM" (XPRESS Huffman) vía ntdll, API documentada en el WDK.
//   Usn            : lectura de solo lectura del USN Journal NTFS (FSCTL_QUERY/READ_USN_JOURNAL).
//   Volumes        : correspondencia letra de unidad <-> dispositivo NT.
//   ProcessMemory  : búsqueda de cadenas en la memoria de un proceso (solo lectura).
//   AuditPolicy    : consulta de la política de auditoría (AuditQuerySystemPolicy).
//
// Ninguna función escribe en el sistema analizado: todos los handles se abren con acceso de lectura
// o sin acceso (solo para consultar nombres).

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace AmonSS.Native
{
    public sealed class MatchResult
    {
        public int[] Patterns;
        public long[] Offsets;
        public long BytesScanned;
        public bool Truncated;
    }

    public sealed class ScanState
    {
        public int State;
        public long Position;
        public bool[] Found;
        public long[] Offsets;
        public List<int> Order;
    }

    // Autómata Aho-Corasick completo (tabla de transiciones densa de 256 columnas).
    // El estado se conserva entre bloques, así que un patrón partido entre dos lecturas se detecta.
    public sealed class PatternMatcher
    {
        private readonly int[] _delta;
        private readonly int[][] _out;
        private readonly int[] _lengths;
        private readonly int _stateCount;

        public int PatternCount { get { return _lengths.Length; } }
        public int StateCount { get { return _stateCount; } }

        public PatternMatcher(byte[][] patterns)
        {
            if (patterns == null) throw new ArgumentNullException("patterns");
            _lengths = new int[patterns.Length];
            List<int[]> go = new List<int[]>();
            List<List<int>> outs = new List<List<int>>();
            go.Add(NewRow());
            outs.Add(null);
            for (int p = 0; p < patterns.Length; p++)
            {
                byte[] pat = patterns[p];
                if (pat == null || pat.Length == 0) throw new ArgumentException("Patrón vacío en el índice " + p);
                _lengths[p] = pat.Length;
                int s = 0;
                for (int i = 0; i < pat.Length; i++)
                {
                    int next = go[s][pat[i]];
                    if (next == -1)
                    {
                        next = go.Count;
                        go[s][pat[i]] = next;
                        go.Add(NewRow());
                        outs.Add(null);
                    }
                    s = next;
                }
                if (outs[s] == null) outs[s] = new List<int>();
                outs[s].Add(p);
            }

            int n = go.Count;
            _stateCount = n;
            int[] fail = new int[n];
            _delta = new int[n * 256];
            Queue<int> queue = new Queue<int>();
            for (int b = 0; b < 256; b++)
            {
                int nx = go[0][b];
                if (nx == -1) { _delta[b] = 0; }
                else { _delta[b] = nx; fail[nx] = 0; queue.Enqueue(nx); }
            }
            while (queue.Count > 0)
            {
                int r = queue.Dequeue();
                List<int> inherited = outs[fail[r]];
                if (inherited != null)
                {
                    if (outs[r] == null) outs[r] = new List<int>();
                    outs[r].AddRange(inherited);
                }
                for (int b = 0; b < 256; b++)
                {
                    int u = go[r][b];
                    if (u == -1) { _delta[r * 256 + b] = _delta[fail[r] * 256 + b]; }
                    else
                    {
                        fail[u] = _delta[fail[r] * 256 + b];
                        _delta[r * 256 + b] = u;
                        queue.Enqueue(u);
                    }
                }
            }
            _out = new int[n][];
            for (int i = 0; i < n; i++) _out[i] = outs[i] == null ? null : outs[i].ToArray();
        }

        private static int[] NewRow()
        {
            int[] row = new int[256];
            for (int i = 0; i < 256; i++) row[i] = -1;
            return row;
        }

        public ScanState NewState()
        {
            ScanState st = new ScanState();
            st.Found = new bool[_lengths.Length];
            st.Offsets = new long[_lengths.Length];
            st.Order = new List<int>();
            return st;
        }

        public void Feed(ScanState st, byte[] data, int offset, int count)
        {
            int s = st.State;
            long basePos = st.Position - offset;
            int end = offset + count;
            for (int i = offset; i < end; i++)
            {
                s = _delta[(s << 8) | data[i]];
                int[] o = _out[s];
                if (o != null)
                {
                    for (int k = 0; k < o.Length; k++)
                    {
                        int p = o[k];
                        if (!st.Found[p])
                        {
                            st.Found[p] = true;
                            st.Offsets[p] = basePos + i - _lengths[p] + 1;
                            st.Order.Add(p);
                        }
                    }
                }
            }
            st.State = s;
            st.Position += count;
        }

        public MatchResult Finish(ScanState st, bool truncated)
        {
            MatchResult r = new MatchResult();
            r.Patterns = st.Order.ToArray();
            r.Offsets = new long[r.Patterns.Length];
            for (int i = 0; i < r.Patterns.Length; i++) r.Offsets[i] = st.Offsets[r.Patterns[i]];
            r.BytesScanned = st.Position;
            r.Truncated = truncated;
            return r;
        }

        public MatchResult ScanBytes(byte[] data)
        {
            ScanState st = NewState();
            if (data != null) Feed(st, data, 0, data.Length);
            return Finish(st, false);
        }

        // Escanea un flujo hasta maxBytes (0 = sin límite). Reinicia el autómata.
        public MatchResult ScanStream(Stream stream, long maxBytes)
        {
            ScanState st = NewState();
            bool truncated = ScanInto(st, stream, maxBytes);
            return Finish(st, truncated);
        }

        // Variante con búfer reutilizable (evita reservar 64 KB por cada entrada de un JAR).
        public MatchResult ScanStream(Stream stream, long maxBytes, byte[] buffer)
        {
            ScanState st = NewState();
            bool truncated = ScanInto(st, stream, maxBytes, buffer);
            return Finish(st, truncated);
        }

        // Alimenta un estado existente con un flujo (para acumular varias entradas de un JAR).
        public bool ScanInto(ScanState st, Stream stream, long maxBytes)
        {
            return ScanInto(st, stream, maxBytes, new byte[65536]);
        }

        public bool ScanInto(ScanState st, Stream stream, long maxBytes, byte[] buf)
        {
            long total = 0;
            while (true)
            {
                int want = buf.Length;
                if (maxBytes > 0)
                {
                    long left = maxBytes - total;
                    if (left <= 0)
                    {
                        // ¿Quedan datos sin leer?
                        int probe = stream.Read(buf, 0, 1);
                        return probe > 0;
                    }
                    if (left < want) want = (int)left;
                }
                int n = stream.Read(buf, 0, want);
                if (n <= 0) return false;
                Feed(st, buf, 0, n);
                total += n;
            }
        }

        public MatchResult ScanFile(string path, long maxBytes)
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, FileOptions.SequentialScan))
            {
                return ScanStream(fs, maxBytes);
            }
        }
    }

    public sealed class JarNameSummary
    {
        public int EntryCount;
        public int ClassCount;
        public bool Truncated;
        public string[] Names;
        public string[] Packages;
        public string[] NestedJars;
        public Dictionary<string, string> Metadata = new Dictionary<string, string>(StringComparer.Ordinal);
    }

    public sealed class NameMatch
    {
        public string Kind;
        public string Key;
        public string Entry;
    }

    // Operaciones sobre la lista de nombres de un JAR (sin descomprimir nada).
    public static class JarNames
    {
        private static void Increment(Dictionary<string, int> d, string key)
        {
            int v;
            d.TryGetValue(key, out v);
            d[key] = v + 1;
        }

        public static JarNameSummary Summarize(string[] all, int maxEntries, string[] metadataNamesLower)
        {
            JarNameSummary s = new JarNameSummary();
            s.EntryCount = all.Length;
            int keep = Math.Min(all.Length, Math.Max(0, maxEntries));
            s.Truncated = keep < all.Length;
            s.Names = new string[keep];
            Array.Copy(all, s.Names, keep);
            Dictionary<string, bool> meta = new Dictionary<string, bool>(StringComparer.Ordinal);
            foreach (string m in metadataNamesLower) meta[m] = true;
            Dictionary<string, int> pkg = new Dictionary<string, int>(StringComparer.Ordinal);
            List<string> nested = new List<string>();
            foreach (string n in all)
            {
                if (n.EndsWith(".class", StringComparison.OrdinalIgnoreCase))
                {
                    s.ClassCount++;
                    int slash = n.LastIndexOf('/');
                    if (slash > 0)
                    {
                        string[] parts = n.Substring(0, slash).Split('/');
                        int depth = Math.Min(3, parts.Length);
                        string prefix = string.Join("/", parts, 0, depth) + "/";
                        Increment(pkg, prefix);
                        if (parts.Length >= 2)
                        {
                            string p2 = parts[0] + "/" + parts[1] + "/";
                            if (p2 != prefix) Increment(pkg, p2);
                        }
                    }
                }
                else if (n.EndsWith(".jar", StringComparison.OrdinalIgnoreCase))
                {
                    nested.Add(n);
                }
                string lower = n.ToLowerInvariant();
                if (meta.ContainsKey(lower) && !s.Metadata.ContainsKey(lower)) s.Metadata[lower] = n;
            }
            List<KeyValuePair<string, int>> list = new List<KeyValuePair<string, int>>();
            foreach (KeyValuePair<string, int> kv in pkg) if (!kv.Key.StartsWith("META-INF/", StringComparison.Ordinal)) list.Add(kv);
            list.Sort(delegate (KeyValuePair<string, int> a, KeyValuePair<string, int> b) { return b.Value.CompareTo(a.Value); });
            int top = Math.Min(10, list.Count);
            s.Packages = new string[top];
            for (int i = 0; i < top; i++) s.Packages[i] = list[i].Key;
            s.NestedJars = nested.ToArray();
            return s;
        }

        // Paquetes (prefijos en límites '/'), entradas conocidas (ruta o nombre de archivo, en
        // minúsculas) y clases exactas. Devuelve solo la primera entrada de cada clave.
        public static List<NameMatch> Match(string[] names, string[] packages, string[] entryKeysLower, string[] classPaths)
        {
            Dictionary<string, bool> pk = new Dictionary<string, bool>(StringComparer.Ordinal);
            Dictionary<string, bool> ek = new Dictionary<string, bool>(StringComparer.Ordinal);
            Dictionary<string, bool> cp = new Dictionary<string, bool>(StringComparer.Ordinal);
            foreach (string p in packages) pk[p] = true;
            foreach (string p in entryKeysLower) ek[p] = true;
            foreach (string p in classPaths) cp[p] = true;
            Dictionary<string, bool> reported = new Dictionary<string, bool>(StringComparer.Ordinal);
            List<NameMatch> result = new List<NameMatch>();
            foreach (string n in names)
            {
                int pos = -1;
                for (int seg = 0; seg < 5; seg++)
                {
                    pos = n.IndexOf('/', pos + 1);
                    if (pos < 0) break;
                    string pre = n.Substring(0, pos + 1);
                    if (pk.ContainsKey(pre) && !reported.ContainsKey("P|" + pre)) { reported["P|" + pre] = true; result.Add(NewMatch("package", pre, n)); }
                }
                string lower = n.ToLowerInvariant();
                int slash = lower.LastIndexOf('/');
                string file = slash >= 0 ? lower.Substring(slash + 1) : lower;
                if (ek.ContainsKey(lower) && !reported.ContainsKey("E|" + lower)) { reported["E|" + lower] = true; result.Add(NewMatch("entry", lower, n)); }
                if (file != lower && ek.ContainsKey(file) && !reported.ContainsKey("E|" + file)) { reported["E|" + file] = true; result.Add(NewMatch("entry", file, n)); }
                if (cp.ContainsKey(n) && !reported.ContainsKey("C|" + n)) { reported["C|" + n] = true; result.Add(NewMatch("class", n, n)); }
            }
            return result;
        }

        private static NameMatch NewMatch(string kind, string key, string entry)
        {
            NameMatch m = new NameMatch();
            m.Kind = kind;
            m.Key = key;
            m.Entry = entry;
            return m;
        }
    }

    public static class Compression
    {
        public const ushort COMPRESSION_FORMAT_XPRESS_HUFF = 4;

        [DllImport("ntdll.dll")]
        private static extern uint RtlGetCompressionWorkSpaceSize(ushort compressionFormatAndEngine, out uint compressBufferWorkSpaceSize, out uint compressFragmentWorkSpaceSize);

        [DllImport("ntdll.dll")]
        private static extern uint RtlDecompressBufferEx(ushort compressionFormat, byte[] uncompressedBuffer, int uncompressedBufferSize,
            byte[] compressedBuffer, int compressedBufferSize, out int finalUncompressedSize, byte[] workSpace);

        public static bool IsMam(byte[] data)
        {
            return data != null && data.Length >= 8 && data[0] == 0x4D && data[1] == 0x41 && data[2] == 0x4D;
        }

        // Prefetch de Windows 10/11: "MAM" + método (4 = XPRESS Huffman; bit alto = hay CRC32)
        // + tamaño descomprimido (4 bytes) + [CRC32] + datos comprimidos.
        public static byte[] DecompressMam(byte[] data)
        {
            if (!IsMam(data)) throw new InvalidDataException("No es un contenedor MAM.");
            int method = data[3] & 0x0F;
            bool hasChecksum = (data[3] & 0x80) != 0;
            if (method != COMPRESSION_FORMAT_XPRESS_HUFF) throw new NotSupportedException("Método MAM no soportado: " + method);
            int size = BitConverter.ToInt32(data, 4);
            if (size <= 0 || size > 64 * 1024 * 1024) throw new InvalidDataException("Tamaño descomprimido inválido: " + size);
            int header = hasChecksum ? 12 : 8;
            if (data.Length <= header) throw new InvalidDataException("Contenedor MAM truncado.");

            uint wsSize, fragSize;
            uint status = RtlGetCompressionWorkSpaceSize(COMPRESSION_FORMAT_XPRESS_HUFF, out wsSize, out fragSize);
            if (status != 0) throw new InvalidOperationException("RtlGetCompressionWorkSpaceSize NTSTATUS 0x" + status.ToString("X8"));

            byte[] compressed = new byte[data.Length - header];
            Buffer.BlockCopy(data, header, compressed, 0, compressed.Length);
            byte[] output = new byte[size];
            byte[] workspace = new byte[Math.Max(fragSize, 16u)];
            int finalSize;
            status = RtlDecompressBufferEx(COMPRESSION_FORMAT_XPRESS_HUFF, output, size, compressed, compressed.Length, out finalSize, workspace);
            if (status != 0) throw new InvalidDataException("RtlDecompressBufferEx NTSTATUS 0x" + status.ToString("X8"));
            if (finalSize != size) Array.Resize(ref output, finalSize);
            return output;
        }
    }

    public sealed class UsnRecordInfo
    {
        public long Usn;
        public DateTime TimestampUtc;
        public ulong FileReference;
        public ulong ParentReference;
        public uint Reason;
        public uint SourceInfo;
        public uint Attributes;
        public int MajorVersion;
        public string FileName;
        public string ParentPath;
        // Para renombrados: nombre y directorio anteriores (registro RENAME_OLD_NAME inmediato).
        public string PreviousName;
        public ulong PreviousParentReference;
        public string PreviousParentPath;
    }

    public sealed class UsnFilterState
    {
        public UsnRecordInfo LastOldName;
    }

    public sealed class UsnJournalInfo
    {
        public ulong JournalId;
        public long FirstUsn;
        public long NextUsn;
        public long LowestValidUsn;
        public long MaxUsn;
        public ulong MaximumSize;
        public ulong AllocationDelta;
    }

    public sealed class UsnFilter
    {
        public DateTime MinTimestampUtc = DateTime.MinValue;
        public DateTime MaxTimestampUtc = DateTime.MaxValue;
        public string[] NameContains;
        public string[] Extensions;
        public string[] DeleteOnlyExtensions;
        public string[] NamePrefixes;
        public ulong[] ParentReferences;
        public bool OnlyFinalRecords = true;
        public bool ResolvePaths = true;
        public int MaxResults = 20000;

        private Dictionary<ulong, bool> _parents;

        internal bool HasParent(ulong reference)
        {
            if (ParentReferences == null || ParentReferences.Length == 0) return false;
            if (_parents == null)
            {
                _parents = new Dictionary<ulong, bool>();
                foreach (ulong r in ParentReferences) _parents[r] = true;
            }
            return _parents.ContainsKey(reference);
        }
    }

    public sealed class UsnScanResult
    {
        public UsnJournalInfo Journal;
        public List<UsnRecordInfo> Records = new List<UsnRecordInfo>();
        public long TotalRecords;
        public DateTime FirstTimestampUtc = DateTime.MinValue;
        public DateTime LastTimestampUtc = DateTime.MinValue;
        public bool Truncated;
        public bool TimedOut;
        public int ErrorCode;
        public string Error;
    }

    public static class Usn
    {
        public const uint USN_REASON_FILE_DELETE = 0x00000200;
        public const uint USN_REASON_RENAME_OLD_NAME = 0x00001000;
        public const uint USN_REASON_RENAME_NEW_NAME = 0x00002000;
        public const uint USN_REASON_CLOSE = 0x80000000;

        private const uint GENERIC_READ = 0x80000000;
        private const uint FILE_SHARE_READ = 0x1, FILE_SHARE_WRITE = 0x2, FILE_SHARE_DELETE = 0x4;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FSCTL_QUERY_USN_JOURNAL = 0x000900F4;
        private const uint FSCTL_READ_USN_JOURNAL = 0x000900BB;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(SafeFileHandle device, uint code, byte[] inBuffer, int inSize, byte[] outBuffer, int outSize, out int bytesReturned, IntPtr overlapped);

        [StructLayout(LayoutKind.Sequential)]
        private struct FILE_ID_DESCRIPTOR
        {
            public uint dwSize;
            public int Type;
            public long FileId;
            public long Reserved;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern SafeFileHandle OpenFileById(SafeFileHandle volumeHint, ref FILE_ID_DESCRIPTOR fileId, uint access, uint share, IntPtr security, uint flags);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint size, uint flags);

        [StructLayout(LayoutKind.Sequential)]
        // Los FILETIME nativos van alineados a 4 bytes (offsets 4/12/20): declararlos como long
        // los desplazaría a 8/16/24 y FileIndexLow acabaría en FileIndexHigh.
        private struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle file, out BY_HANDLE_FILE_INFORMATION info);

        // Interpreta registros USN_RECORD_V2 / V3 consecutivos.
        public static List<UsnRecordInfo> ParseRecords(byte[] buffer, int offset, int length)
        {
            List<UsnRecordInfo> list = new List<UsnRecordInfo>();
            int pos = offset;
            int end = Math.Min(buffer.Length, offset + length);
            while (pos + 8 <= end)
            {
                int recLen = BitConverter.ToInt32(buffer, pos);
                if (recLen < 60 || pos + recLen > end) break;
                ushort major = BitConverter.ToUInt16(buffer, pos + 4);
                UsnRecordInfo r = null;
                if (major == 2) r = ParseV2(buffer, pos, recLen);
                else if (major == 3) r = ParseV3(buffer, pos, recLen);
                if (r != null) list.Add(r);
                pos += recLen;
            }
            return list;
        }

        private static DateTime FromFileTime(long ft)
        {
            if (ft <= 0) return DateTime.MinValue;
            try { return DateTime.FromFileTimeUtc(ft); } catch { return DateTime.MinValue; }
        }

        private static string ReadName(byte[] b, int recordStart, int recLen, int lengthField, int offsetField)
        {
            int nameLen = BitConverter.ToUInt16(b, recordStart + lengthField);
            int nameOff = BitConverter.ToUInt16(b, recordStart + offsetField);
            if (nameOff + nameLen > recLen) return null;
            return Encoding.Unicode.GetString(b, recordStart + nameOff, nameLen);
        }

        private static UsnRecordInfo ParseV2(byte[] b, int p, int recLen)
        {
            UsnRecordInfo r = new UsnRecordInfo();
            r.MajorVersion = 2;
            r.FileReference = BitConverter.ToUInt64(b, p + 8);
            r.ParentReference = BitConverter.ToUInt64(b, p + 16);
            r.Usn = BitConverter.ToInt64(b, p + 24);
            r.TimestampUtc = FromFileTime(BitConverter.ToInt64(b, p + 32));
            r.Reason = BitConverter.ToUInt32(b, p + 40);
            r.SourceInfo = BitConverter.ToUInt32(b, p + 44);
            r.Attributes = BitConverter.ToUInt32(b, p + 52);
            r.FileName = ReadName(b, p, recLen, 56, 58);
            return r.FileName == null ? null : r;
        }

        private static UsnRecordInfo ParseV3(byte[] b, int p, int recLen)
        {
            if (recLen < 76) return null;
            UsnRecordInfo r = new UsnRecordInfo();
            r.MajorVersion = 3;
            // FILE_ID_128: en NTFS la referencia de 64 bits ocupa los 8 bytes bajos.
            r.FileReference = BitConverter.ToUInt64(b, p + 8);
            r.ParentReference = BitConverter.ToUInt64(b, p + 24);
            r.Usn = BitConverter.ToInt64(b, p + 40);
            r.TimestampUtc = FromFileTime(BitConverter.ToInt64(b, p + 48));
            r.Reason = BitConverter.ToUInt32(b, p + 56);
            r.SourceInfo = BitConverter.ToUInt32(b, p + 60);
            r.Attributes = BitConverter.ToUInt32(b, p + 68);
            r.FileName = ReadName(b, p, recLen, 72, 74);
            return r.FileName == null ? null : r;
        }

        private static bool EndsWithAny(string name, string[] list)
        {
            if (list == null) return false;
            for (int i = 0; i < list.Length; i++)
                if (!string.IsNullOrEmpty(list[i]) && name.EndsWith(list[i], StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        public static bool Matches(UsnRecordInfo r, UsnFilter f)
        {
            if (f.OnlyFinalRecords && (r.Reason & USN_REASON_CLOSE) == 0 && (r.Reason & USN_REASON_RENAME_OLD_NAME) == 0) return false;
            if (r.TimestampUtc < f.MinTimestampUtc || r.TimestampUtc > f.MaxTimestampUtc) return false;
            if (f.HasParent(r.ParentReference)) return true;
            string name = r.FileName ?? string.Empty;
            if (f.NamePrefixes != null)
                for (int i = 0; i < f.NamePrefixes.Length; i++)
                    if (!string.IsNullOrEmpty(f.NamePrefixes[i]) && name.StartsWith(f.NamePrefixes[i], StringComparison.OrdinalIgnoreCase)) return true;
            if (EndsWithAny(name, f.Extensions)) return true;
            if ((r.Reason & (USN_REASON_FILE_DELETE | USN_REASON_RENAME_OLD_NAME | USN_REASON_RENAME_NEW_NAME)) != 0 && EndsWithAny(name, f.DeleteOnlyExtensions)) return true;
            if (f.NameContains != null)
                for (int i = 0; i < f.NameContains.Length; i++)
                    if (!string.IsNullOrEmpty(f.NameContains[i]) && name.IndexOf(f.NameContains[i], StringComparison.OrdinalIgnoreCase) >= 0) return true;
            return false;
        }

        // Aplica el filtro a una secuencia de registros en orden USN. Conserva el último
        // RENAME_OLD_NAME visto (aunque no coincida) para adjuntarlo al RENAME_NEW_NAME del mismo
        // archivo: así se conoce el nombre original de lo que se movió a $Recycle.Bin.
        public static List<UsnRecordInfo> Apply(IEnumerable<UsnRecordInfo> records, UsnFilter filter, UsnFilterState state)
        {
            List<UsnRecordInfo> kept = new List<UsnRecordInfo>();
            foreach (UsnRecordInfo r in records)
            {
                if ((r.Reason & USN_REASON_RENAME_OLD_NAME) != 0) state.LastOldName = r;
                else if ((r.Reason & USN_REASON_RENAME_NEW_NAME) != 0 && state.LastOldName != null && state.LastOldName.FileReference == r.FileReference)
                {
                    r.PreviousName = state.LastOldName.FileName;
                    r.PreviousParentReference = state.LastOldName.ParentReference;
                }
                bool match = Matches(r, filter);
                if (!match && r.PreviousName != null && (r.Reason & USN_REASON_CLOSE) != 0)
                {
                    // Un renombrado cuyo nombre anterior era relevante también interesa.
                    UsnRecordInfo probe = new UsnRecordInfo();
                    probe.Reason = r.Reason; probe.TimestampUtc = r.TimestampUtc; probe.FileName = r.PreviousName; probe.ParentReference = r.PreviousParentReference;
                    match = Matches(probe, filter);
                }
                if (!match) continue;
                kept.Add(r);
            }
            return kept;
        }

        // Con el máximo alcanzado se descartan los registros más antiguos: en una revisión
        // importa lo reciente. Devuelve true si se descartó algo.
        public static bool TrimToNewest(List<UsnRecordInfo> records, int max)
        {
            if (max <= 0 || records.Count <= max) return false;
            records.RemoveRange(0, records.Count - max);
            return true;
        }

        public static UsnJournalInfo ParseJournalData(byte[] q)
        {
            UsnJournalInfo info = new UsnJournalInfo();
            info.JournalId = BitConverter.ToUInt64(q, 0);
            info.FirstUsn = BitConverter.ToInt64(q, 8);
            info.NextUsn = BitConverter.ToInt64(q, 16);
            info.LowestValidUsn = BitConverter.ToInt64(q, 24);
            info.MaxUsn = BitConverter.ToInt64(q, 32);
            info.MaximumSize = BitConverter.ToUInt64(q, 40);
            info.AllocationDelta = BitConverter.ToUInt64(q, 48);
            return info;
        }

        // Lee el journal del volumen (requiere administrador). No modifica ni limpia nada.
        public static UsnScanResult ReadJournal(string drive, UsnFilter filter, DateTime deadlineUtc)
        {
            UsnScanResult result = new UsnScanResult();
            string letter = drive.TrimEnd('\\').TrimEnd(':');
            using (SafeFileHandle h = CreateFileW(@"\\.\" + letter + ":", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero))
            {
                if (h.IsInvalid)
                {
                    result.ErrorCode = Marshal.GetLastWin32Error();
                    result.Error = "No se pudo abrir el volumen (error " + result.ErrorCode + ").";
                    return result;
                }
                byte[] q = new byte[80];
                int ret;
                if (!DeviceIoControl(h, FSCTL_QUERY_USN_JOURNAL, null, 0, q, q.Length, out ret, IntPtr.Zero))
                {
                    result.ErrorCode = Marshal.GetLastWin32Error();
                    result.Error = result.ErrorCode == 1179 ? "El USN Journal no está activo en este volumen." : "FSCTL_QUERY_USN_JOURNAL falló (error " + result.ErrorCode + ").";
                    return result;
                }
                result.Journal = ParseJournalData(q);

                long start = result.Journal.FirstUsn;
                long stopAt = result.Journal.NextUsn;
                byte[] input = new byte[40];
                byte[] output = new byte[1 << 20];
                Dictionary<ulong, string> pathCache = new Dictionary<ulong, string>();
                UsnFilterState state = new UsnFilterState();
                while (start < stopAt)
                {
                    if (DateTime.UtcNow > deadlineUtc) { result.TimedOut = true; break; }
                    Array.Clear(input, 0, input.Length);
                    Buffer.BlockCopy(BitConverter.GetBytes(start), 0, input, 0, 8);
                    Buffer.BlockCopy(BitConverter.GetBytes(0xFFFFFFFFu), 0, input, 8, 4);
                    Buffer.BlockCopy(BitConverter.GetBytes(result.Journal.JournalId), 0, input, 32, 8);
                    if (!DeviceIoControl(h, FSCTL_READ_USN_JOURNAL, input, input.Length, output, output.Length, out ret, IntPtr.Zero))
                    {
                        result.ErrorCode = Marshal.GetLastWin32Error();
                        result.Error = "FSCTL_READ_USN_JOURNAL falló (error " + result.ErrorCode + ").";
                        break;
                    }
                    if (ret <= 8) break;
                    long next = BitConverter.ToInt64(output, 0);
                    List<UsnRecordInfo> batch = ParseRecords(output, 8, ret - 8);
                    foreach (UsnRecordInfo r in batch)
                    {
                        result.TotalRecords++;
                        if (r.TimestampUtc != DateTime.MinValue)
                        {
                            if (result.FirstTimestampUtc == DateTime.MinValue) result.FirstTimestampUtc = r.TimestampUtc;
                            result.LastTimestampUtc = r.TimestampUtc;
                        }
                    }
                    foreach (UsnRecordInfo r in Apply(batch, filter, state))
                    {
                        if (filter.ResolvePaths)
                        {
                            r.ParentPath = ResolveCached(h, r.ParentReference, pathCache);
                            if (r.PreviousName != null) r.PreviousParentPath = ResolveCached(h, r.PreviousParentReference, pathCache);
                        }
                        result.Records.Add(r);
                    }
                    // Recorte por tandas para no crecer sin límite mientras se lee.
                    if (filter.MaxResults > 0 && result.Records.Count >= 2 * filter.MaxResults && TrimToNewest(result.Records, filter.MaxResults)) result.Truncated = true;
                    if (next <= start) break;
                    start = next;
                }
                if (TrimToNewest(result.Records, filter.MaxResults)) result.Truncated = true;
            }
            return result;
        }

        private static string ResolveCached(SafeFileHandle volume, ulong reference, Dictionary<ulong, string> cache)
        {
            string path;
            if (!cache.TryGetValue(reference, out path))
            {
                path = ResolveById(volume, reference);
                cache[reference] = path;
            }
            return path;
        }

        // Ruta actual de un archivo/directorio a partir de su referencia NTFS (null si ya no existe).
        public static string ResolveById(SafeFileHandle volumeHint, ulong fileReference)
        {
            FILE_ID_DESCRIPTOR d = new FILE_ID_DESCRIPTOR();
            d.dwSize = 24;
            d.Type = 0;
            d.FileId = unchecked((long)fileReference);
            using (SafeFileHandle fh = OpenFileById(volumeHint, ref d, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, FILE_FLAG_BACKUP_SEMANTICS))
            {
                if (fh.IsInvalid) return null;
                StringBuilder sb = new StringBuilder(1024);
                uint n = GetFinalPathNameByHandleW(fh, sb, (uint)sb.Capacity, 0);
                if (n == 0) return null;
                if (n > sb.Capacity)
                {
                    sb = new StringBuilder((int)n + 1);
                    n = GetFinalPathNameByHandleW(fh, sb, (uint)sb.Capacity, 0);
                    if (n == 0) return null;
                }
                return StripLongPrefix(sb.ToString());
            }
        }

        public static string StripLongPrefix(string p)
        {
            if (p == null) return null;
            if (p.StartsWith(@"\\?\UNC\")) return @"\\" + p.Substring(8);
            if (p.StartsWith(@"\\?\")) return p.Substring(4);
            return p;
        }

        // Ruta final (resolviendo junctions y enlaces) de un archivo o directorio existente.
        public static string GetFinalPath(string path)
        {
            using (SafeFileHandle h = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero))
            {
                if (h.IsInvalid) return null;
                StringBuilder sb = new StringBuilder(1024);
                uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
                if (n == 0 || n > sb.Capacity) return null;
                return StripLongPrefix(sb.ToString());
            }
        }

        // Referencia NTFS (64 bits, incluye número de secuencia) de un archivo o directorio.
        // Se abre sin derechos de acceso: no requiere administrador.
        public static ulong GetFileReference(string path)
        {
            using (SafeFileHandle h = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero))
            {
                if (h.IsInvalid) return 0;
                BY_HANDLE_FILE_INFORMATION info;
                if (!GetFileInformationByHandle(h, out info)) return 0;
                return ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
            }
        }
    }

    public static class Volumes
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern uint QueryDosDeviceW(string deviceName, StringBuilder targetPath, int max);

        // "C:" -> "\Device\HarddiskVolume3"
        public static string QueryDosDevice(string drive)
        {
            string name = drive.TrimEnd('\\');
            if (!name.EndsWith(":")) name += ":";
            StringBuilder sb = new StringBuilder(1024);
            uint n = QueryDosDeviceW(name, sb, sb.Capacity);
            if (n == 0) return null;
            return sb.ToString();
        }
    }

    public sealed class MemoryScanResult
    {
        public int[] Patterns = new int[0];
        public long[] Addresses = new long[0];
        public long BytesScanned;
        public int Regions;
        public int UnreadableRegions;
        public bool Truncated;
        public bool TimedOut;
        public string Error;
        public int ErrorCode;
    }

    // Escaneo de cadenas en la memoria de un proceso, de solo lectura: se abre con
    // PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, se recorren las regiones comprometidas y
    // legibles con VirtualQueryEx y se leen con ReadProcessMemory. Nunca se escribe ni se
    // suspende el proceso, y no se guarda nada de su contenido: solo qué patrones aparecen.
    public static class ProcessMemory
    {
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private const uint PROCESS_VM_READ = 0x0010;
        private const uint MEM_COMMIT = 0x1000;
        private const uint PAGE_NOACCESS = 0x01;
        private const uint PAGE_GUARD = 0x100;
        private const uint READABLE = 0x02 | 0x04 | 0x08 | 0x20 | 0x40 | 0x80;

        // Con LayoutKind.Sequential el relleno coincide con MEMORY_BASIC_INFORMATION en x86 (28
        // bytes) y en x64 (48 bytes: 4 de relleno tras AllocationProtect y 4 al final).
        [StructLayout(LayoutKind.Sequential)]
        private struct MEMORY_BASIC_INFORMATION
        {
            public IntPtr BaseAddress;
            public IntPtr AllocationBase;
            public uint AllocationProtect;
            public IntPtr RegionSize;
            public uint State;
            public uint Protect;
            public uint Type;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr VirtualQueryEx(IntPtr process, IntPtr address, out MEMORY_BASIC_INFORMATION info, IntPtr length);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, IntPtr size, out IntPtr read);

        public static MemoryScanResult Scan(int processId, PatternMatcher matcher, long maxBytes, DateTime deadlineUtc)
        {
            MemoryScanResult result = new MemoryScanResult();
            IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, processId);
            if (h == IntPtr.Zero) h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, false, processId);
            if (h == IntPtr.Zero)
            {
                result.ErrorCode = Marshal.GetLastWin32Error();
                result.Error = "No se pudo abrir el proceso para lectura (error " + result.ErrorCode + ").";
                return result;
            }
            try
            {
                ScanState st = matcher.NewState();
                byte[] buf = new byte[4 << 20];
                int mbiSize = Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION));
                long address = 0;
                long limit = IntPtr.Size == 8 ? 0x7FFFFFFFFFFFL : 0x7FFFFFFFL;
                while (address < limit)
                {
                    if (DateTime.UtcNow > deadlineUtc) { result.TimedOut = true; break; }
                    MEMORY_BASIC_INFORMATION mbi;
                    if (VirtualQueryEx(h, new IntPtr(address), out mbi, new IntPtr(mbiSize)) == IntPtr.Zero) break;
                    long regionBase = mbi.BaseAddress.ToInt64();
                    long regionSize = mbi.RegionSize.ToInt64();
                    if (regionSize <= 0) break;
                    bool readable = mbi.State == MEM_COMMIT && (mbi.Protect & PAGE_GUARD) == 0 && (mbi.Protect & PAGE_NOACCESS) == 0 && (mbi.Protect & READABLE) != 0;
                    if (readable)
                    {
                        result.Regions++;
                        // Cada región empieza con el autómata a cero (no se unen cadenas de regiones
                        // distintas) y la posición en su dirección: los desplazamientos son direcciones.
                        st.State = 0;
                        st.Position = regionBase;
                        long done = 0;
                        bool anyRead = false;
                        while (done < regionSize)
                        {
                            if (maxBytes > 0 && result.BytesScanned >= maxBytes) { result.Truncated = true; break; }
                            int want = (int)Math.Min(buf.Length, regionSize - done);
                            IntPtr got;
                            if (!ReadProcessMemory(h, new IntPtr(regionBase + done), buf, new IntPtr(want), out got) || got.ToInt64() <= 0)
                            {
                                // Página liberada o protegida entre la consulta y la lectura: se salta.
                                st.State = 0;
                                done += want;
                                st.Position = regionBase + done;
                                continue;
                            }
                            anyRead = true;
                            int n = (int)got.ToInt64();
                            matcher.Feed(st, buf, 0, n);
                            result.BytesScanned += n;
                            done += n;
                            if (n < want) { st.State = 0; st.Position = regionBase + done; }
                        }
                        if (!anyRead) result.UnreadableRegions++;
                        if (result.Truncated) break;
                    }
                    address = regionBase + regionSize;
                }
                MatchResult m = matcher.Finish(st, result.Truncated || result.TimedOut);
                result.Patterns = m.Patterns;
                result.Addresses = m.Offsets;
            }
            finally { CloseHandle(h); }
            return result;
        }

        // Devuelve (sin repetir) el texto ASCII imprimible que sigue a cada aparición de 'marker'
        // hasta 'stop' o un carácter no imprimible, con 'maxLength' caracteres como máximo. Solo
        // regiones privadas de lectura/escritura (donde viven los datos del programa). Lo usa
        // Amon SS para las trazas PcaClient de explorer.exe; el resto de la memoria no se guarda.
        public static List<string> ExtractAfter(int processId, byte[] marker, byte stop, int maxLength, int maxResults, long maxBytes, DateTime deadlineUtc)
        {
            List<string> found = new List<string>();
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, processId);
            if (h == IntPtr.Zero) h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, false, processId);
            if (h == IntPtr.Zero) throw new InvalidOperationException("No se pudo abrir el proceso para lectura (error " + Marshal.GetLastWin32Error() + ").");
            try
            {
                int chunk = 4 << 20;
                int overlap = marker.Length + maxLength;
                byte[] buf = new byte[chunk + overlap];
                int mbiSize = Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION));
                long address = 0, total = 0;
                long limit = IntPtr.Size == 8 ? 0x7FFFFFFFFFFFL : 0x7FFFFFFFL;
                while (address < limit && found.Count < maxResults && DateTime.UtcNow <= deadlineUtc && (maxBytes <= 0 || total < maxBytes))
                {
                    MEMORY_BASIC_INFORMATION mbi;
                    if (VirtualQueryEx(h, new IntPtr(address), out mbi, new IntPtr(mbiSize)) == IntPtr.Zero) break;
                    long regionBase = mbi.BaseAddress.ToInt64(), regionSize = mbi.RegionSize.ToInt64();
                    if (regionSize <= 0) break;
                    bool rw = mbi.State == MEM_COMMIT && mbi.Type == 0x20000 && (mbi.Protect & PAGE_GUARD) == 0 && (mbi.Protect & 0x04) != 0;
                    if (rw)
                    {
                        for (long done = 0; done < regionSize && found.Count < maxResults; done += chunk)
                        {
                            int want = (int)Math.Min(chunk + overlap, regionSize - done);
                            IntPtr got;
                            if (!ReadProcessMemory(h, new IntPtr(regionBase + done), buf, new IntPtr(want), out got)) continue;
                            int n = (int)got.ToInt64();
                            total += n;
                            int last = n - marker.Length;
                            for (int i = 0; i <= last; i++)
                            {
                                if (buf[i] != marker[0]) continue;
                                int k = 1;
                                while (k < marker.Length && buf[i + k] == marker[k]) k++;
                                if (k < marker.Length) continue;
                                int s = i + marker.Length, e = s;
                                while (e < n && e - s < maxLength && buf[e] != stop && buf[e] >= 0x20 && buf[e] < 0x7F) e++;
                                if (e > s && (e < n || e - s >= maxLength))
                                {
                                    string text = Encoding.ASCII.GetString(buf, s, e - s);
                                    if (seen.Add(text)) { found.Add(text); if (found.Count >= maxResults) break; }
                                }
                                i = e;
                            }
                        }
                    }
                    address = regionBase + regionSize;
                }
            }
            finally { CloseHandle(h); }
            return found;
        }
    }

    public static class AuditPolicy
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct AUDIT_POLICY_INFORMATION
        {
            public Guid AuditSubCategoryGuid;
            public uint AuditingInformation;
            public Guid AuditCategoryGuid;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct TOKEN_PRIVILEGES
        {
            public int PrivilegeCount;
            public long Luid;
            public int Attributes;
        }

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool AuditQuerySystemPolicy([In] Guid[] subCategoryGuids, uint policyCount, out IntPtr auditPolicy);

        [DllImport("advapi32.dll")]
        private static extern void AuditFree(IntPtr buffer);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool LookupPrivilegeValueW(string system, string name, out long luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES newState, int bufferLength, IntPtr previousState, IntPtr returnLength);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        private const uint TOKEN_ADJUST_PRIVILEGES = 0x20, TOKEN_QUERY = 0x8;
        private const int SE_PRIVILEGE_ENABLED = 0x2;

        private static bool SetPrivilege(string name, bool enable)
        {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token)) return false;
            try
            {
                long luid;
                if (!LookupPrivilegeValueW(null, name, out luid)) return false;
                TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                tp.PrivilegeCount = 1;
                tp.Luid = luid;
                tp.Attributes = enable ? SE_PRIVILEGE_ENABLED : 0;
                if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
                return Marshal.GetLastWin32Error() == 0;
            }
            finally { CloseHandle(token); }
        }

        // Devuelve los flags de auditoría de la subcategoría (1 = éxito, 2 = error, 0 = ninguno)
        // o -1 si no se pudo consultar. Para consultar, Windows exige SeSecurityPrivilege: si el
        // proceso es administrador se habilita solo durante la llamada y se vuelve a deshabilitar.
        public static int QuerySubcategory(Guid subcategory, out int lastError)
        {
            lastError = 0;
            int value = TryQuery(subcategory, out lastError);
            if (value >= 0) return value;
            if (lastError == 1314 || lastError == 5)
            {
                if (SetPrivilege("SeSecurityPrivilege", true))
                {
                    try { value = TryQuery(subcategory, out lastError); }
                    finally { SetPrivilege("SeSecurityPrivilege", false); }
                }
            }
            return value;
        }

        private static int TryQuery(Guid subcategory, out int lastError)
        {
            lastError = 0;
            IntPtr buffer;
            if (!AuditQuerySystemPolicy(new Guid[] { subcategory }, 1, out buffer))
            {
                lastError = Marshal.GetLastWin32Error();
                return -1;
            }
            try
            {
                AUDIT_POLICY_INFORMATION info = (AUDIT_POLICY_INFORMATION)Marshal.PtrToStructure(buffer, typeof(AUDIT_POLICY_INFORMATION));
                return (int)(info.AuditingInformation & 0x3);
            }
            finally { AuditFree(buffer); }
        }
    }
}
