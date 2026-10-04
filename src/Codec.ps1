# Schema-driven protobuf codec (C#, compiled at import). Parses the proto3 text in
# Schemas.ps1 into field tables; decodes to case-insensitive Hashtables and encodes
# from IDictionary. Kept C# 5 compatible for Windows PowerShell 5.1.

if (-not ([System.Management.Automation.PSTypeName]'PirateTok.Live.ProtoCodec').Type) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace PirateTok.Live {
    public class TikTokLiveException : Exception {
        public string ErrorKind { get; private set; }
        public long Code { get; private set; }
        public TikTokLiveException(string kind, string message) : base(message) { ErrorKind = kind; }
        public TikTokLiveException(string kind, string message, long code) : base(message) { ErrorKind = kind; Code = code; }
    }

    // TLS validation: system trust, plus one exactly pinned certificate when set
    // (offline tests pin their self-signed fake server; null = system trust only).
    public static class TlsTrust {
        public static string PinnedThumbprint;
        public static bool Validate(object sender, System.Security.Cryptography.X509Certificates.X509Certificate cert,
                System.Security.Cryptography.X509Certificates.X509Chain chain, System.Net.Security.SslPolicyErrors errors) {
            if (errors == System.Net.Security.SslPolicyErrors.None) return true;
            return PinnedThumbprint != null && cert != null &&
                string.Equals(cert.GetCertHashString(), PinnedThumbprint, StringComparison.OrdinalIgnoreCase);
        }
    }

    public class ProtoField {
        public string Name; public int Tag; public string Kind; public bool Repeated;
    }

    public static class ProtoCodec {
        static readonly Dictionary<string, Dictionary<int, ProtoField>> Schemas =
            new Dictionary<string, Dictionary<int, ProtoField>>();
        static readonly HashSet<string> Scalars = new HashSet<string> {
            "int32", "int64", "uint32", "uint64", "sint32", "sint64", "bool", "string", "bytes",
            "fixed32", "sfixed32", "float", "fixed64", "sfixed64", "double" };

        // Additive: later texts may reference types from earlier ones.
        public static void Load(string text) {
            var noComments = Regex.Replace(text, @"//[^\n]*", "");
            var fieldRe = new Regex(@"(repeated\s+)?(map<[^>]+>|[A-Za-z_][\w.]*)\s+(\w+)\s*=\s*(\d+)\s*;");
            foreach (Match m in Regex.Matches(noComments, @"message\s+(\w+)\s*\{([^}]*)\}")) {
                var fields = new Dictionary<int, ProtoField>();
                foreach (Match f in fieldRe.Matches(m.Groups[2].Value)) {
                    if (f.Groups[2].Value.StartsWith("map<")) continue; // maps unused by the client
                    var pf = new ProtoField {
                        Repeated = f.Groups[1].Success, Kind = f.Groups[2].Value,
                        Name = f.Groups[3].Value, Tag = int.Parse(f.Groups[4].Value) };
                    fields[pf.Tag] = pf;
                }
                Schemas[m.Groups[1].Value] = fields;
            }
            foreach (var s in Schemas)
                foreach (var f in s.Value.Values)
                    if (!Scalars.Contains(f.Kind) && !Schemas.ContainsKey(f.Kind))
                        throw new InvalidDataException(s.Key + "." + f.Name + ": unknown type " + f.Kind);
        }

        public static bool Has(string type) { return Schemas.ContainsKey(type); }

        static int ExpectedWire(string kind) {
            switch (kind) {
                case "fixed64": case "sfixed64": case "double": return 1;
                case "fixed32": case "sfixed32": case "float": return 5;
                case "string": case "bytes": return 2;
                default: return Scalars.Contains(kind) ? 0 : 2;
            }
        }

        public static ulong ReadVarint(byte[] d, ref int p, int end) {
            ulong r = 0; int s = 0;
            while (true) {
                if (p >= end) throw new InvalidDataException("truncated varint");
                byte b = d[p++];
                if (s < 64) r |= ((ulong)(b & 0x7F)) << s;
                if ((b & 0x80) == 0) return r;
                s += 7;
                if (s > 70) throw new InvalidDataException("varint too long");
            }
        }

        static object Scalar(string kind, ulong v) {
            switch (kind) {
                case "bool": return v != 0;
                case "uint64": return v;
                case "sint32": case "sint64": return (long)(v >> 1) ^ -(long)(v & 1);
                case "int32": return (long)(int)v;
                default: return (long)v;
            }
        }

        static object Default(ProtoField f) {
            if (f.Repeated) return new object[0];
            switch (f.Kind) {
                case "bool": return false;
                case "string": return "";
                case "bytes": return new byte[0];
                case "uint64": return (ulong)0;
                case "float": case "double": return 0.0;
                default: return Scalars.Contains(f.Kind) ? (object)(long)0 : null;
            }
        }

        public static Hashtable Decode(string type, byte[] data) {
            return Decode(type, data, 0, data.Length);
        }

        static Hashtable Decode(string type, byte[] d, int p, int end) {
            Dictionary<int, ProtoField> schema;
            if (!Schemas.TryGetValue(type, out schema)) throw new InvalidDataException("no schema " + type);
            var lists = new Dictionary<int, ArrayList>();
            var h = new Hashtable(StringComparer.OrdinalIgnoreCase);
            foreach (var f in schema.Values) h[f.Name] = Default(f);
            while (p < end) {
                ulong key = ReadVarint(d, ref p, end);
                int tag = (int)(key >> 3), wire = (int)(key & 7);
                if (tag == 0) throw new InvalidDataException("field tag 0");
                ProtoField f;
                if (!schema.TryGetValue(tag, out f)) { Skip(d, ref p, end, wire); continue; }
                int expected = ExpectedWire(f.Kind);
                if (f.Repeated && wire == 2 && expected != 2) { // packed scalars
                    int len = checked((int)ReadVarint(d, ref p, end)); int stop = p + len;
                    if (len < 0 || stop > end) throw new InvalidDataException("truncated packed field");
                    while (p < stop) Add(lists, f, ReadScalar(f.Kind, expected, d, ref p, stop));
                    continue;
                }
                if (wire != expected)
                    throw new InvalidDataException(type + "." + f.Name + ": wire type " + wire + " != " + expected);
                object v;
                if (wire == 2) {
                    int len = checked((int)ReadVarint(d, ref p, end));
                    if (len < 0 || p + len > end) throw new InvalidDataException("truncated field " + f.Name);
                    if (f.Kind == "string") v = Encoding.UTF8.GetString(d, p, len);
                    else if (f.Kind == "bytes") { var b = new byte[len]; Buffer.BlockCopy(d, p, b, 0, len); v = b; }
                    else v = Decode(f.Kind, d, p, p + len);
                    p += len;
                } else v = ReadScalar(f.Kind, wire, d, ref p, end);
                if (f.Repeated) Add(lists, f, v); else h[f.Name] = v;
            }
            foreach (var kv in lists) h[schema[kv.Key].Name] = kv.Value.ToArray();
            return h;
        }

        static void Add(Dictionary<int, ArrayList> lists, ProtoField f, object v) {
            ArrayList l;
            if (!lists.TryGetValue(f.Tag, out l)) { l = new ArrayList(); lists[f.Tag] = l; }
            l.Add(v);
        }

        static object ReadScalar(string kind, int wire, byte[] d, ref int p, int end) {
            if (wire == 0) return Scalar(kind, ReadVarint(d, ref p, end));
            int n = wire == 1 ? 8 : 4;
            if (p + n > end) throw new InvalidDataException("truncated fixed field");
            object v;
            if (wire == 1) v = kind == "double" ? (object)BitConverter.ToDouble(d, p) : BitConverter.ToInt64(d, p);
            else v = kind == "float" ? (object)(double)BitConverter.ToSingle(d, p) : (long)BitConverter.ToInt32(d, p);
            p += n;
            return v;
        }

        static void Skip(byte[] d, ref int p, int end, int wire) {
            switch (wire) {
                case 0: ReadVarint(d, ref p, end); break;
                case 1: p += 8; break;
                case 5: p += 4; break;
                case 2: int len = checked((int)ReadVarint(d, ref p, end)); p += len; break;
                default: throw new InvalidDataException("unsupported wire type " + wire);
            }
            if (p > end) throw new InvalidDataException("truncated skipped field");
        }

        // ---- encode ----

        public static byte[] Encode(string type, IDictionary values) {
            Dictionary<int, ProtoField> schema;
            if (!Schemas.TryGetValue(type, out schema)) throw new InvalidDataException("no schema " + type);
            var ms = new MemoryStream();
            var tags = new List<int>(schema.Keys); tags.Sort();
            foreach (int tag in tags) {
                var f = schema[tag];
                if (!values.Contains(f.Name) || values[f.Name] == null) continue;
                object v = values[f.Name];
                if (f.Repeated && !(v is string) && v is IEnumerable) {
                    foreach (object item in (IEnumerable)v) if (item != null) WriteField(ms, f, item);
                } else WriteField(ms, f, v);
            }
            return ms.ToArray();
        }

        static void WriteField(MemoryStream ms, ProtoField f, object v) {
            int wire = ExpectedWire(f.Kind);
            WriteVarint(ms, ((ulong)(uint)f.Tag << 3) | (uint)wire);
            if (wire == 2) {
                byte[] b;
                if (f.Kind == "string") b = Encoding.UTF8.GetBytes(Convert.ToString(v));
                else if (f.Kind == "bytes") b = (byte[])v;
                else b = Encode(f.Kind, (IDictionary)v);
                WriteVarint(ms, (ulong)b.Length); ms.Write(b, 0, b.Length);
            } else if (wire == 0) {
                ulong u;
                if (v is bool) u = (bool)v ? 1UL : 0UL;
                else if (v is ulong) u = (ulong)v;
                else if (f.Kind == "sint32" || f.Kind == "sint64") { long l = Convert.ToInt64(v); u = (ulong)((l << 1) ^ (l >> 63)); }
                else if (f.Kind == "uint64") u = Convert.ToUInt64(v);
                else u = unchecked((ulong)Convert.ToInt64(v));
                WriteVarint(ms, u);
            } else {
                byte[] b = wire == 1 ? BitConverter.GetBytes(Convert.ToInt64(v)) : BitConverter.GetBytes(Convert.ToInt32(v));
                ms.Write(b, 0, b.Length);
            }
        }

        public static void WriteVarint(MemoryStream ms, ulong v) {
            while (v > 0x7F) { ms.WriteByte((byte)((v & 0x7F) | 0x80)); v >>= 7; }
            ms.WriteByte((byte)v);
        }
    }
}
'@
}

[PirateTok.Live.ProtoCodec]::Load($script:ProtoSchemaText)

function ConvertFrom-TikTokProto([string]$Type, [byte[]]$Data) {
    return [PirateTok.Live.ProtoCodec]::Decode($Type, $Data)
}

function ConvertTo-TikTokProto([string]$Type, [System.Collections.IDictionary]$Values) {
    return , [PirateTok.Live.ProtoCodec]::Encode($Type, $Values)
}

function New-TikTokError([string]$Kind, [string]$Message, [long]$Code = 0) {
    return [PirateTok.Live.TikTokLiveException]::new($Kind, $Message, $Code)
}

function Expand-TikTokGzip([byte[]]$Data) {
    if ($Data.Length -lt 2 -or $Data[0] -ne 0x1f -or $Data[1] -ne 0x8b) { return , $Data }
    $in = [System.IO.MemoryStream]::new($Data)
    $gz = [System.IO.Compression.GZipStream]::new($in, [System.IO.Compression.CompressionMode]::Decompress)
    $out = [System.IO.MemoryStream]::new()
    $gz.CopyTo($out)
    $gz.Dispose(); $in.Dispose()
    $bytes = $out.ToArray(); $out.Dispose()
    return , $bytes
}
