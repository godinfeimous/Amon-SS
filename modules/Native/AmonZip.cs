// Amon SS - escaneo del contenido de entradas ZIP/JAR con el autómata de firmas (C# 5).
// Se compila junto a AmonNative.cs (sus directivas using aplican a toda la unidad). Necesita
// System.IO.Compression; si no compila, Signatures.psm1 usa su bucle equivalente en PowerShell.


namespace AmonSS.Native
{
    public sealed class ZipEntryHit
    {
        public int Pattern;
        public string Entry;
        public long Offset;
    }

    public sealed class ZipContentResult
    {
        public List<ZipEntryHit> Hits = new List<ZipEntryHit>();
        public List<string> NestedArchives = new List<string>();
        public List<string> Errors = new List<string>();
        public int EntriesScanned;
        public long BytesScanned;
        public int SkippedLarge;
        public bool Truncated;
    }

    public static class ZipContentScanner
    {
        private static string Extension(string name)
        {
            int dot = name.LastIndexOf('.');
            int slash = name.LastIndexOf('/');
            return (dot > slash && dot >= 0) ? name.Substring(dot) : string.Empty;
        }

        public static string[] GetEntryNames(System.IO.Compression.ZipArchive zip)
        {
            List<string> names = new List<string>();
            foreach (System.IO.Compression.ZipArchiveEntry e in zip.Entries) names.Add(e.FullName);
            return names.ToArray();
        }

        // Recorre todas las entradas (salvo multimedia y archivos anidados, que se devuelven en
        // NestedArchives) y registra la primera aparición de cada patrón en todo el JAR.
        public static ZipContentResult Scan(PatternMatcher matcher, System.IO.Compression.ZipArchive zip, long maxEntry, long maxTotal, int maxEntries,
            string[] skipExtensions, string[] archiveExtensions)
        {
            ZipContentResult res = new ZipContentResult();
            Dictionary<string, bool> skip = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            Dictionary<string, bool> arch = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            foreach (string s in skipExtensions) skip[s] = true;
            foreach (string s in archiveExtensions) arch[s] = true;
            bool[] seen = new bool[matcher.PatternCount];
            byte[] buffer = new byte[65536];
            foreach (System.IO.Compression.ZipArchiveEntry e in zip.Entries)
            {
                if (res.BytesScanned >= maxTotal || res.EntriesScanned >= maxEntries) { res.Truncated = true; break; }
                string name = e.FullName;
                if (name.EndsWith("/")) continue;
                string ext = Extension(name);
                if (skip.ContainsKey(ext)) continue;
                if (arch.ContainsKey(ext)) { res.NestedArchives.Add(name); continue; }
                if (e.Length > maxEntry) { res.SkippedLarge++; continue; }
                try
                {
                    using (Stream s = e.Open())
                    {
                        MatchResult r = matcher.ScanStream(s, maxEntry, buffer);
                        res.EntriesScanned++;
                        res.BytesScanned += r.BytesScanned;
                        for (int i = 0; i < r.Patterns.Length; i++)
                        {
                            int p = r.Patterns[i];
                            if (seen[p]) continue;
                            seen[p] = true;
                            ZipEntryHit h = new ZipEntryHit();
                            h.Pattern = p;
                            h.Entry = name;
                            h.Offset = r.Offsets[i];
                            res.Hits.Add(h);
                        }
                    }
                }
                catch (Exception ex) { res.Errors.Add(name + ": " + ex.Message); }
            }
            return res;
        }
    }
}
