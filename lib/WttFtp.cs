// Windows Transfer Tool - minimal FTP / FTPS (explicit TLS) server and client.
//
// Compiled at run time by Migrate-Windows.ps1 with Add-Type, so it must stay
//   * C# 5 compatible (Windows PowerShell 5.1 uses the old csc compiler),
//   * ASCII only.
//
// Design (kept deliberately small - this is for a one-off copy on a trusted LAN):
//   Server  read-only view of a few folders, passive mode only, one user, one random password,
//           optional explicit TLS (AUTH TLS) with a self-signed certificate, 5 failed logins
//           locks it, can be restricted to one client address once the new PC has bound.
//           The only thing a client may write are files that were allowed one by one
//           (bound.json / done.json), at most 64 KB each.
//   Client  just enough FTP to list (MLSD), download (RETR) and upload (STOR), plus a
//           multi-connection mirror used by the destination PC.
//   Both sides speak standard FTP, so Explorer, WinSCP, FileZilla or curl can also connect
//   to the server by hand (see docs/manual.md).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

namespace Wtt
{
    public class FtpException : Exception
    {
        public int Code;
        public FtpException(int code, string message) : base(message) { Code = code; }
    }

    public static class FtpUtil
    {
        public static string Sha256Hex(byte[] data)
        {
            using (SHA256 sha = SHA256.Create())
            {
                byte[] h = sha.ComputeHash(data);
                StringBuilder sb = new StringBuilder();
                foreach (byte b in h) sb.Append(b.ToString("X2"));
                return sb.ToString();
            }
        }

        // Upper-case hex without separators, so "ab:cd 12" and "ABCD12" compare equal.
        public static string NormalizeHex(string s)
        {
            if (s == null) return null;
            StringBuilder sb = new StringBuilder();
            foreach (char c in s)
            {
                if (Uri.IsHexDigit(c)) sb.Append(char.ToUpperInvariant(c));
            }
            return sb.ToString();
        }

        // Self-signed server certificate, valid for a couple of days, never written to a certificate store.
        public static X509Certificate2 CreateSelfSigned(string commonName, int days)
        {
            using (RSA rsa = RSA.Create())
            {
                rsa.KeySize = 2048;
                CertificateRequest req = new CertificateRequest("CN=" + commonName, rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                req.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, false));
                OidCollection eku = new OidCollection();
                eku.Add(new Oid("1.3.6.1.5.5.7.3.1"));
                req.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(eku, false));
                X509Certificate2 tmp = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(days));
                // Schannel cannot use an ephemeral key directly; a PFX round trip gives it one it can open.
                byte[] pfx = tmp.Export(X509ContentType.Pfx, "wtt");
                tmp.Dispose();
                // Activator, because newer .NET marks this constructor obsolete (an error for Add-Type) while
                // .NET Framework has nothing else to offer.
                return (X509Certificate2)Activator.CreateInstance(typeof(X509Certificate2), pfx, "wtt", X509KeyStorageFlags.Exportable);
            }
        }

        public static string FormatTime(DateTime utc)
        {
            return utc.ToString("yyyyMMddHHmmss", CultureInfo.InvariantCulture);
        }
    }

    // ------------------------------------------------------------------------------------------
    // SERVER
    // ------------------------------------------------------------------------------------------
    public class FtpServer : IDisposable
    {
        readonly IPAddress bindAddr;
        readonly int port, pasvLow, pasvHigh;
        readonly string user, password;
        readonly X509Certificate2 cert;                       // null = plain FTP
        readonly Dictionary<string, string> roots = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, bool> uploads = new Dictionary<string, bool>();   // lower-case virtual paths
        readonly Dictionary<string, bool> hidden = new Dictionary<string, bool>();
        readonly List<TcpClient> active = new List<TcpClient>();
        readonly Random rnd = new Random();
        TcpListener listener;
        Thread acceptThread;
        volatile bool stopping;
        int sessions;
        int failures;
        string allowedIp;

        public string LastLoginIp;
        public long FilesServed;
        public long BytesServed;
        public int MaxFailures = 5;

        public FtpServer(IPAddress bind, int port, int pasvLow, int pasvHigh, string user, string password, X509Certificate2 cert)
        {
            this.bindAddr = bind; this.port = port; this.pasvLow = pasvLow; this.pasvHigh = pasvHigh;
            this.user = user; this.password = password; this.cert = cert;
        }

        public int Port { get { return port; } }
        public bool Locked { get { return failures >= MaxFailures; } }
        public bool Tls { get { return cert != null; } }

        // Read-only folder visible to the client as /name.
        public void AddRoot(string name, string realPath) { lock (roots) { roots[name] = realPath; } }
        // The client may STOR exactly this virtual path (small files only).
        public void AllowUpload(string virtualPath) { uploads[virtualPath.ToLowerInvariant()] = true; }
        // The client can neither see nor read this virtual path.
        public void Hide(string virtualPath) { hidden[virtualPath.ToLowerInvariant()] = true; }
        // After binding: refuse every address except this one.
        public void AllowOnly(string ip) { allowedIp = ip; }

        public void Start()
        {
            listener = new TcpListener(bindAddr, port);
            listener.Start(16);
            acceptThread = new Thread(AcceptLoop);
            acceptThread.IsBackground = true;
            acceptThread.Start();
        }

        public void Stop()
        {
            stopping = true;
            try { if (listener != null) listener.Stop(); } catch (Exception) { }
            lock (active) { foreach (TcpClient c in active) { try { c.Close(); } catch (Exception) { } } active.Clear(); }
        }

        public void Dispose() { Stop(); if (cert != null) cert.Dispose(); }

        void AcceptLoop()
        {
            while (!stopping)
            {
                TcpClient c;
                try { c = listener.AcceptTcpClient(); }
                catch (Exception) { if (stopping) break; continue; }
                string ip = "";
                try { ip = ((IPEndPoint)c.Client.RemoteEndPoint).Address.ToString(); } catch (Exception) { }
                string only = allowedIp;
                if (only != null && ip != only) { try { c.Close(); } catch (Exception) { } continue; }
                if (Interlocked.Increment(ref sessions) > 16)
                {
                    Interlocked.Decrement(ref sessions);
                    try { byte[] b = Encoding.ASCII.GetBytes("421 Too many connections\r\n"); c.GetStream().Write(b, 0, b.Length); c.Close(); } catch (Exception) { }
                    continue;
                }
                lock (active) { active.Add(c); }
                Session s = new Session(this, c, ip);
                Thread t = new Thread(s.Run);
                t.IsBackground = true;
                t.Start();
            }
        }

        bool IsHidden(string virt) { return hidden.ContainsKey(virt.ToLowerInvariant()); }

        bool CheckLogin(string u, string p)
        {
            byte[] a = Encoding.UTF8.GetBytes(password);
            byte[] b = Encoding.UTF8.GetBytes(p ?? "");
            int diff = a.Length ^ b.Length;
            for (int i = 0; i < a.Length; i++) { int bv = i < b.Length ? b[i] : 0; diff |= a[i] ^ bv; }
            return diff == 0 && string.Equals(u, user, StringComparison.Ordinal);
        }

        TcpListener OpenPassive()
        {
            int count = pasvHigh - pasvLow + 1;
            int start;
            lock (rnd) { start = rnd.Next(count); }
            for (int i = 0; i < count; i++)
            {
                int p = pasvLow + ((start + i) % count);
                try { TcpListener l = new TcpListener(IPAddress.Any, p); l.Start(1); return l; }
                catch (SocketException) { }
            }
            return null;
        }

        static readonly string[] Reserved = new string[] { "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" };

        static bool SafeSegment(string s)
        {
            if (s.Length == 0 || s.Length > 255) return false;
            foreach (char c in s)
            {
                if (c < 32 || c == '\\' || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|') return false;
            }
            if (s.EndsWith(".") || s.EndsWith(" ")) return false;
            int dot = s.IndexOf('.');
            string stem = (dot < 0 ? s : s.Substring(0, dot)).ToUpperInvariant();
            foreach (string r in Reserved) { if (stem == r) return false; }
            return true;
        }

        sealed class Node
        {
            public bool IsRootList;
            public string Real;
            public string Virt;
        }

        sealed class Session
        {
            readonly FtpServer srv;
            readonly TcpClient client;
            readonly string remoteIp;
            Stream ctl;
            bool tls, protP, authed;
            string pendingUser;
            List<string> cwd = new List<string>();
            TcpListener pasv;
            long restart;

            public Session(FtpServer srv, TcpClient client, string remoteIp)
            {
                this.srv = srv; this.client = client; this.remoteIp = remoteIp;
            }

            public void Run()
            {
                try
                {
                    client.ReceiveTimeout = 120000;
                    client.SendTimeout = 120000;
                    ctl = client.GetStream();
                    Reply(220, "Windows Transfer Tool ready");
                    string line;
                    while ((line = ReadLine()) != null)
                    {
                        if (!Handle(line)) break;
                    }
                }
                catch (Exception) { }
                finally
                {
                    ClosePasv();
                    try { client.Close(); } catch (Exception) { }
                    lock (srv.active) { srv.active.Remove(client); }
                    Interlocked.Decrement(ref srv.sessions);
                }
            }

            string ReadLine()
            {
                List<byte> buf = new List<byte>();
                while (true)
                {
                    int b = ctl.ReadByte();
                    if (b < 0) return buf.Count == 0 ? null : Encoding.UTF8.GetString(buf.ToArray());
                    if (b == '\n') break;
                    if (b != '\r') buf.Add((byte)b);
                    if (buf.Count > 4096) throw new IOException("line too long");
                }
                return Encoding.UTF8.GetString(buf.ToArray());
            }

            void Write(string s)
            {
                byte[] b = Encoding.UTF8.GetBytes(s);
                ctl.Write(b, 0, b.Length);
                ctl.Flush();
            }

            void Reply(int code, string text) { Write(code.ToString() + " " + text + "\r\n"); }

            void ClosePasv()
            {
                if (pasv != null) { try { pasv.Stop(); } catch (Exception) { } pasv = null; }
            }

            bool Handle(string line)
            {
                int sp = line.IndexOf(' ');
                string cmd = (sp < 0 ? line : line.Substring(0, sp)).ToUpperInvariant();
                string arg = sp < 0 ? "" : line.Substring(sp + 1).Trim();

                switch (cmd)
                {
                    case "USER":
                        if (srv.Tls && !tls) { Reply(530, "Use AUTH TLS first"); return true; }
                        pendingUser = arg; authed = false; Reply(331, "Password required"); return true;
                    case "PASS":
                        if (srv.Tls && !tls) { Reply(530, "Use AUTH TLS first"); return true; }
                        if (srv.Locked) { Reply(530, "Locked after too many failed logins"); return false; }
                        if (pendingUser != null && srv.CheckLogin(pendingUser, arg))
                        {
                            authed = true; srv.LastLoginIp = remoteIp; Reply(230, "Logged in"); return true;
                        }
                        Thread.Sleep(1000);
                        Interlocked.Increment(ref srv.failures);
                        Reply(530, "Login incorrect");
                        return !srv.Locked;
                    case "AUTH":
                        {
                            string m = arg.ToUpperInvariant();
                            if (srv.cert == null || (m != "TLS" && m != "TLS-C" && m != "SSL" && m != "TLS-P")) { Reply(504, "Not supported"); return true; }
                            if (tls) { Reply(503, "Already using TLS"); return true; }
                            Reply(234, "Proceed with TLS negotiation");
                            SslStream ss = new SslStream(ctl, false);
                            ss.AuthenticateAsServer(srv.cert, false, SslProtocols.Tls12, false);
                            ctl = ss; tls = true; authed = false; pendingUser = null;
                            return true;
                        }
                    case "PBSZ": if (!tls) { Reply(503, "AUTH TLS first"); } else { Reply(200, "PBSZ=0"); } return true;
                    case "PROT":
                        {
                            string m = arg.ToUpperInvariant();
                            if (!tls) { Reply(503, "AUTH TLS first"); }
                            else if (m == "P") { protP = true; Reply(200, "Data connections are protected"); }
                            else if (m == "C") { Reply(534, "Clear data connections are not allowed"); }
                            else { Reply(504, "Unknown protection level"); }
                            return true;
                        }
                    case "FEAT":
                        {
                            StringBuilder sb = new StringBuilder("211-Features\r\n UTF8\r\n MLST type*;size*;modify*;perm*;\r\n MLSD\r\n SIZE\r\n MDTM\r\n REST STREAM\r\n EPSV\r\n PASV\r\n");
                            if (srv.cert != null) sb.Append(" AUTH TLS\r\n PBSZ\r\n PROT\r\n");
                            sb.Append("211 End\r\n");
                            Write(sb.ToString());
                            return true;
                        }
                    case "OPTS": Reply(200, "OK"); return true;
                    case "SYST": Reply(215, "UNIX Type: L8"); return true;
                    case "NOOP": Reply(200, "OK"); return true;
                    case "QUIT": Reply(221, "Goodbye"); return false;
                }

                if (!authed) { Reply(530, "Please log in"); return true; }

                switch (cmd)
                {
                    case "TYPE": case "MODE": case "STRU": Reply(200, "OK"); return true;
                    case "PWD": case "XPWD": Reply(257, "\"/" + string.Join("/", cwd.ToArray()) + "\" is the current directory"); return true;
                    case "CWD": case "XCWD": case "CDUP":
                        {
                            Node n = Resolve(cmd == "CDUP" ? ".." : arg);
                            if (n != null && (n.IsRootList || (n.Real != null && Directory.Exists(n.Real))))
                            {
                                cwd = new List<string>(n.Virt.Split(new char[] { '/' }, StringSplitOptions.RemoveEmptyEntries));
                                Reply(250, "OK");
                            }
                            else Reply(550, "No such directory");
                            return true;
                        }
                    case "PASV": case "EPSV":
                        {
                            if (cmd == "EPSV" && arg.ToUpperInvariant() == "ALL") { Reply(200, "OK"); return true; }
                            ClosePasv();
                            pasv = srv.OpenPassive();
                            if (pasv == null) { Reply(425, "No free data port"); return true; }
                            int p = ((IPEndPoint)pasv.LocalEndpoint).Port;
                            if (cmd == "EPSV") { Reply(229, "Entering Extended Passive Mode (|||" + p + "|)"); return true; }
                            IPAddress la = ((IPEndPoint)client.Client.LocalEndPoint).Address;
                            Reply(227, "Entering Passive Mode (" + la.ToString().Replace('.', ',') + "," + (p >> 8) + "," + (p & 255) + ")");
                            return true;
                        }
                    case "REST":
                        { long r; if (long.TryParse(arg, out r) && r >= 0) { restart = r; Reply(350, "Restarting at " + r); } else Reply(501, "Bad offset"); return true; }
                    case "SIZE":
                        {
                            Node n = Resolve(arg);
                            if (n != null && n.Real != null && File.Exists(n.Real)) Reply(213, new FileInfo(n.Real).Length.ToString());
                            else Reply(550, "No such file");
                            return true;
                        }
                    case "MDTM":
                        {
                            Node n = Resolve(arg);
                            if (n != null && n.Real != null && File.Exists(n.Real)) Reply(213, FtpUtil.FormatTime(File.GetLastWriteTimeUtc(n.Real)));
                            else Reply(550, "No such file");
                            return true;
                        }
                    case "LIST": case "NLST": case "MLSD": DoList(cmd, arg); return true;
                    case "RETR": DoRetr(arg); return true;
                    case "STOR": DoStor(arg); return true;
                    case "ABOR": Reply(226, "OK"); return true;
                    case "DELE": case "RMD": case "XRMD": case "MKD": case "XMKD": case "RNFR": case "RNTO": case "APPE": case "STOU":
                        Reply(550, "This server is read-only"); return true;
                    default:
                        Reply(502, "Command not implemented"); return true;
                }
            }

            Node Resolve(string arg)
            {
                List<string> segs = new List<string>();
                string p = arg ?? "";
                if (!p.StartsWith("/")) segs.AddRange(cwd);
                foreach (string part in p.Split('/'))
                {
                    if (part.Length == 0 || part == ".") continue;
                    if (part == "..") { if (segs.Count > 0) segs.RemoveAt(segs.Count - 1); continue; }
                    if (!SafeSegment(part)) return null;
                    segs.Add(part);
                }
                Node n = new Node();
                n.Virt = "/" + string.Join("/", segs.ToArray());
                if (segs.Count == 0) { n.IsRootList = true; return n; }
                string root;
                lock (srv.roots) { if (!srv.roots.TryGetValue(segs[0], out root)) return null; }
                string cur = root;
                for (int i = 1; i < segs.Count; i++)
                {
                    cur = Path.Combine(cur, segs[i]);
                    // Never follow a junction or symbolic link inside a shared folder: it could lead anywhere.
                    try { if (Directory.Exists(cur) && (File.GetAttributes(cur) & FileAttributes.ReparsePoint) != 0) return null; }
                    catch (Exception) { return null; }
                }
                if (srv.IsHidden(n.Virt)) return null;
                n.Real = cur;
                return n;
            }

            // Opens the passive data connection (after sending 150). Returns null after replying with an error.
            Stream OpenData(out TcpClient dc)
            {
                dc = null;
                if (pasv == null) { Reply(425, "Use PASV or EPSV first"); return null; }
                if (srv.Tls && !protP) { Reply(522, "Use PROT P first"); return null; }
                Reply(150, "Opening data connection");
                DateTime end = DateTime.UtcNow.AddSeconds(20);
                while (DateTime.UtcNow < end)
                {
                    if (pasv.Pending())
                    {
                        TcpClient t = pasv.AcceptTcpClient();
                        string rip = "";
                        try { rip = ((IPEndPoint)t.Client.RemoteEndPoint).Address.ToString(); } catch (Exception) { }
                        if (rip == remoteIp) { dc = t; break; }
                        t.Close();    // somebody else tried to grab the data port
                    }
                    else Thread.Sleep(20);
                }
                ClosePasv();
                if (dc == null) { Reply(425, "No data connection"); return null; }
                dc.SendTimeout = 60000; dc.ReceiveTimeout = 60000;
                Stream s = dc.GetStream();
                if (protP)
                {
                    SslStream ss = new SslStream(s, false);
                    ss.AuthenticateAsServer(srv.cert, false, SslProtocols.Tls12, false);
                    s = ss;
                }
                return s;
            }

            static void CloseData(Stream s, TcpClient dc)
            {
                try { s.Flush(); } catch (Exception) { }
                try { s.Close(); } catch (Exception) { }
                try { dc.Close(); } catch (Exception) { }
            }

            void DoList(string cmd, string arg)
            {
                try
                {
                    while (arg.StartsWith("-")) { int i = arg.IndexOf(' '); arg = i < 0 ? "" : arg.Substring(i + 1).Trim(); }
                    Node n = Resolve(arg);
                    StringBuilder sb = new StringBuilder();
                    DateTime now = DateTime.UtcNow;
                    if (n == null || (!n.IsRootList && !Directory.Exists(n.Real))) { Reply(550, "No such directory"); return; }
                    if (n.IsRootList)
                    {
                        List<string> names;
                        lock (srv.roots) { names = new List<string>(srv.roots.Keys); }
                        names.Sort(StringComparer.OrdinalIgnoreCase);
                        foreach (string name in names) AppendLine(sb, cmd, name, true, 0, now);
                    }
                    else
                    {
                        string vbase = n.Virt.TrimEnd('/');
                        foreach (FileSystemInfo fi in new DirectoryInfo(n.Real).GetFileSystemInfos())
                        {
                            bool isDir = (fi.Attributes & FileAttributes.Directory) != 0;
                            if (isDir && (fi.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                            if (srv.IsHidden(vbase + "/" + fi.Name)) continue;
                            long size = 0;
                            if (!isDir) { try { size = ((FileInfo)fi).Length; } catch (Exception) { } }
                            AppendLine(sb, cmd, fi.Name, isDir, size, fi.LastWriteTimeUtc);
                        }
                    }
                    TcpClient dc;
                    Stream data = OpenData(out dc);
                    if (data == null) return;
                    try
                    {
                        byte[] b = Encoding.UTF8.GetBytes(sb.ToString());
                        data.Write(b, 0, b.Length);
                        CloseData(data, dc);
                        Reply(226, "Listing complete");
                    }
                    catch (Exception) { CloseData(data, dc); Reply(426, "Listing aborted"); }
                }
                catch (UnauthorizedAccessException) { ClosePasv(); Reply(550, "Access denied"); }
                catch (IOException) { ClosePasv(); Reply(550, "Cannot read directory"); }
            }

            static void AppendLine(StringBuilder sb, string cmd, string name, bool isDir, long size, DateTime utc)
            {
                if (cmd == "NLST") { sb.Append(name).Append("\r\n"); return; }
                if (cmd == "MLSD")
                {
                    sb.Append("type=").Append(isDir ? "dir" : "file").Append(";");
                    if (!isDir) sb.Append("size=").Append(size).Append(";");
                    if (utc.Year > 1980) sb.Append("modify=").Append(FtpUtil.FormatTime(utc)).Append(";");
                    sb.Append("perm=").Append(isDir ? "el" : "r").Append("; ").Append(name).Append("\r\n");
                    return;
                }
                string when = utc.Year > 1980 ? utc.ToString("MMM dd HH:mm", CultureInfo.InvariantCulture) : "Jan 01 00:00";
                sb.Append(isDir ? "dr-xr-xr-x" : "-r--r--r--").Append(" 1 ftp ftp ").Append(size.ToString().PadLeft(12)).Append(" ").Append(when).Append(" ").Append(name).Append("\r\n");
            }

            void DoRetr(string arg)
            {
                long offset = restart; restart = 0;
                Node n = Resolve(arg);
                if (n == null || n.Real == null || !File.Exists(n.Real)) { ClosePasv(); Reply(550, "No such file"); return; }
                FileStream fs;
                try { fs = new FileStream(n.Real, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, FileOptions.SequentialScan); }
                catch (Exception) { ClosePasv(); Reply(550, "Cannot open file (in use or access denied)"); return; }
                using (fs)
                {
                    TcpClient dc;
                    Stream data = OpenData(out dc);
                    if (data == null) return;
                    try
                    {
                        if (offset > 0) fs.Seek(offset, SeekOrigin.Begin);
                        byte[] buf = new byte[65536];
                        int r;
                        while ((r = fs.Read(buf, 0, buf.Length)) > 0)
                        {
                            data.Write(buf, 0, r);
                            Interlocked.Add(ref srv.BytesServed, r);
                        }
                        CloseData(data, dc);
                        Interlocked.Increment(ref srv.FilesServed);
                        Reply(226, "Transfer complete");
                    }
                    catch (Exception) { CloseData(data, dc); Reply(426, "Transfer aborted"); }
                }
            }

            void DoStor(string arg)
            {
                Node n = Resolve(arg);
                if (n == null || n.Real == null || !srv.uploads.ContainsKey(n.Virt.ToLowerInvariant())) { ClosePasv(); Reply(550, "Upload not allowed here"); return; }
                TcpClient dc;
                Stream data = OpenData(out dc);
                if (data == null) return;
                try
                {
                    MemoryStream ms = new MemoryStream();
                    byte[] buf = new byte[4096];
                    int r;
                    while ((r = data.Read(buf, 0, buf.Length)) > 0)
                    {
                        ms.Write(buf, 0, r);
                        if (ms.Length > 65536) { CloseData(data, dc); Reply(552, "File too large"); return; }
                    }
                    CloseData(data, dc);
                    string tmp = n.Real + ".part";
                    File.WriteAllBytes(tmp, ms.ToArray());
                    if (File.Exists(n.Real)) File.Delete(n.Real);
                    File.Move(tmp, n.Real);
                    Reply(226, "Stored");
                }
                catch (Exception) { CloseData(data, dc); Reply(451, "Upload failed"); }
            }
        }
    }

    // ------------------------------------------------------------------------------------------
    // CLIENT
    // ------------------------------------------------------------------------------------------
    public class FtpEntry
    {
        public string Name;
        public bool IsDir;
        public long Size;
        public DateTime ModifiedUtc;
    }

    public class FtpReply
    {
        public int Code;
        public string Text;
    }

    public sealed class FtpClient : IDisposable
    {
        readonly string host;
        readonly int port;
        readonly bool tls;
        readonly string pin;                  // required prefix of the server certificate SHA-256 (hex), or null
        TcpClient tcp;
        TcpClient dataTcp;
        Stream ctl;

        public string Fingerprint;            // SHA-256 of the server certificate, set during Connect() for FTPS
        public MirrorJob Progress;            // optional: byte counter updated while downloading

        public FtpClient(string host, int port, bool tls, string pin)
        {
            this.host = host; this.port = port; this.tls = tls;
            this.pin = string.IsNullOrEmpty(pin) ? null : FtpUtil.NormalizeHex(pin);
        }

        TcpClient ConnectTcp(int port)
        {
            TcpClient t = new TcpClient();
            IAsyncResult ar = t.BeginConnect(host, port, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(8000))
            {
                try { t.Close(); } catch (Exception) { }
                throw new FtpException(0, "Timed out connecting to " + host + ":" + port);
            }
            t.EndConnect(ar);
            t.ReceiveTimeout = 60000; t.SendTimeout = 60000;
            return t;
        }

        bool ValidateCert(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors)
        {
            if (cert == null) return false;
            string fp = FtpUtil.Sha256Hex(cert.GetRawCertData());
            if (Fingerprint == null)
            {
                // First handshake (control connection): remember it, enforce the pin if there is one.
                if (pin != null && !fp.StartsWith(pin, StringComparison.OrdinalIgnoreCase)) return false;
                Fingerprint = fp;
                return true;
            }
            return string.Equals(fp, Fingerprint, StringComparison.OrdinalIgnoreCase);   // data connections must match
        }

        Stream WrapTls(Stream s)
        {
            SslStream ss = new SslStream(s, false, ValidateCert);
            try { ss.AuthenticateAsClient(host, null, SslProtocols.Tls12, false); }
            catch (AuthenticationException ex)
            {
                throw new FtpException(0, "TLS handshake failed (certificate fingerprint does not match the one you expected?): " + ex.Message);
            }
            return ss;
        }

        // Opens the control connection, reads the banner and (FTPS) negotiates TLS. Does not log in.
        public void Connect()
        {
            tcp = ConnectTcp(port);
            ctl = tcp.GetStream();
            FtpReply r = ReadReply();
            if (r.Code != 220) throw new FtpException(r.Code, "Unexpected greeting: " + r.Text);
            if (tls)
            {
                r = Command("AUTH TLS");
                if (r.Code != 234) throw new FtpException(r.Code, "The server does not offer TLS: " + r.Text);
                ctl = WrapTls(ctl);
            }
        }

        public void Login(string user, string pass)
        {
            FtpReply r = Command("USER " + user);
            if (r.Code == 331) r = Command("PASS " + pass);
            if (r.Code != 230) throw new FtpException(r.Code, "Login failed: " + r.Text);
            if (tls) { Command("PBSZ 0"); Command("PROT P"); }
            Command("TYPE I");
            Command("OPTS UTF8 ON");
        }

        // "Ftps" if the server at host:port offers TLS, "Ftp" if it is plain FTP, null if nothing FTP-like answers.
        public static string Probe(string host, int port)
        {
            try
            {
                using (FtpClient c = new FtpClient(host, port, false, null))
                {
                    c.Connect();
                    FtpReply r = c.Command("AUTH TLS");
                    return r.Code == 234 ? "Ftps" : "Ftp";
                }
            }
            catch (Exception) { return null; }
        }

        FtpReply ReadReply()
        {
            string line = ReadLine();
            if (line == null) throw new FtpException(0, "The server closed the connection");
            int code;
            if (line.Length < 3 || !int.TryParse(line.Substring(0, 3), out code)) throw new FtpException(0, "Unexpected reply: " + line);
            StringBuilder text = new StringBuilder(line.Length > 4 ? line.Substring(4) : "");
            if (line.Length > 3 && line[3] == '-')
            {
                string end = code.ToString() + " ";
                while (true)
                {
                    line = ReadLine();
                    if (line == null) throw new FtpException(0, "The server closed the connection");
                    text.Append("\n").Append(line);
                    if (line.StartsWith(end)) break;
                }
            }
            FtpReply r = new FtpReply();
            r.Code = code; r.Text = text.ToString();
            return r;
        }

        string ReadLine()
        {
            List<byte> buf = new List<byte>();
            while (true)
            {
                int b = ctl.ReadByte();
                if (b < 0) return buf.Count == 0 ? null : Encoding.UTF8.GetString(buf.ToArray());
                if (b == '\n') break;
                if (b != '\r') buf.Add((byte)b);
                if (buf.Count > 8192) throw new FtpException(0, "Reply line too long");
            }
            return Encoding.UTF8.GetString(buf.ToArray());
        }

        public FtpReply Command(string cmd)
        {
            if (cmd.IndexOf('\r') >= 0 || cmd.IndexOf('\n') >= 0) throw new FtpException(0, "Illegal character in command");
            byte[] b = Encoding.UTF8.GetBytes(cmd + "\r\n");
            ctl.Write(b, 0, b.Length);
            ctl.Flush();
            return ReadReply();
        }

        // Connects the data socket only. For FTPS the TLS handshake must wait until the server has
        // answered the transfer command (150), otherwise both sides wait for the other to speak first.
        Stream OpenPassive()
        {
            int dport;
            FtpReply r = Command("EPSV");
            if (r.Code == 229)
            {
                int a = r.Text.IndexOf("|||");
                int z = r.Text.IndexOf('|', a + 3);
                if (a < 0 || z < 0 || !int.TryParse(r.Text.Substring(a + 3, z - a - 3), out dport)) throw new FtpException(229, "Cannot parse EPSV reply: " + r.Text);
            }
            else
            {
                r = Command("PASV");
                if (r.Code != 227) throw new FtpException(r.Code, "Passive mode failed: " + r.Text);
                int a = r.Text.IndexOf('(');
                int z = r.Text.IndexOf(')');
                string[] p = a >= 0 && z > a ? r.Text.Substring(a + 1, z - a - 1).Split(',') : new string[0];
                int p1, p2;
                if (p.Length != 6 || !int.TryParse(p[4], out p1) || !int.TryParse(p[5], out p2)) throw new FtpException(227, "Cannot parse PASV reply: " + r.Text);
                dport = p1 * 256 + p2;
            }
            dataTcp = ConnectTcp(dport);       // always the control address, never the one in the reply
            return dataTcp.GetStream();
        }

        void CloseData(Stream s)
        {
            try { if (s != null) s.Close(); } catch (Exception) { }
            try { if (dataTcp != null) dataTcp.Close(); } catch (Exception) { }
            dataTcp = null;
        }

        Stream BeginTransfer(string cmd)
        {
            Stream d = OpenPassive();
            FtpReply r;
            try { r = Command(cmd); }
            catch (Exception) { CloseData(d); throw; }
            if (r.Code != 125 && r.Code != 150) { CloseData(d); throw new FtpException(r.Code, r.Text); }
            if (!tls) return d;
            try { return WrapTls(d); }
            catch (Exception) { CloseData(d); throw; }
        }

        void EndTransfer(Stream d)
        {
            CloseData(d);
            FtpReply r = ReadReply();
            if (r.Code != 226 && r.Code != 250) throw new FtpException(r.Code, "Transfer failed: " + r.Text);
        }

        static int ReadSome(Stream s, byte[] buf)
        {
            // The server may close TLS abruptly at the end; EndTransfer still checks the final 226 reply.
            try { return s.Read(buf, 0, buf.Length); } catch (IOException) { return 0; }
        }

        public List<FtpEntry> List(string path)
        {
            Stream d = BeginTransfer("MLSD " + path);
            MemoryStream ms = new MemoryStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = ReadSome(d, buf)) > 0) ms.Write(buf, 0, n);
            EndTransfer(d);

            List<FtpEntry> list = new List<FtpEntry>();
            string text = Encoding.UTF8.GetString(ms.ToArray());
            foreach (string raw in text.Split('\n'))
            {
                string line = raw.TrimEnd('\r');
                int sp = line.IndexOf(' ');
                if (sp <= 0) continue;
                string name = line.Substring(sp + 1);
                FtpEntry e = new FtpEntry();
                e.Name = name;
                bool skip = false;
                foreach (string fact in line.Substring(0, sp).Split(';'))
                {
                    int eq = fact.IndexOf('=');
                    if (eq <= 0) continue;
                    string k = fact.Substring(0, eq).ToLowerInvariant();
                    string v = fact.Substring(eq + 1);
                    if (k == "type") { if (v == "dir") e.IsDir = true; else if (v != "file") skip = true; }
                    else if (k == "size") { long sz; if (long.TryParse(v, out sz)) e.Size = sz; }
                    else if (k == "modify")
                    {
                        DateTime dt;
                        string t = v.Length >= 14 ? v.Substring(0, 14) : v;
                        if (DateTime.TryParseExact(t, "yyyyMMddHHmmss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out dt)) e.ModifiedUtc = dt;
                    }
                }
                if (!skip) list.Add(e);
            }
            return list;
        }

        public void Download(string remote, string localFile, long expectedSize)
        {
            Stream d = BeginTransfer("RETR " + remote);
            long total = 0;
            try
            {
                using (FileStream fs = new FileStream(localFile, FileMode.Create, FileAccess.Write, FileShare.None, 65536))
                {
                    byte[] buf = new byte[65536];
                    int n;
                    while ((n = ReadSome(d, buf)) > 0)
                    {
                        fs.Write(buf, 0, n);
                        total += n;
                        if (Progress != null) Interlocked.Add(ref Progress.BytesDone, n);
                    }
                }
            }
            catch (Exception) { CloseData(d); throw; }
            EndTransfer(d);
            // A file that grew while it was copied is fine (same as robocopy); a short one is not.
            if (expectedSize >= 0 && total < expectedSize) throw new FtpException(0, "Short transfer (" + total + " of " + expectedSize + " bytes)");
        }

        public void Upload(string remote, byte[] data)
        {
            Stream d = BeginTransfer("STOR " + remote);
            try { d.Write(data, 0, data.Length); d.Flush(); }
            catch (Exception) { CloseData(d); throw; }
            EndTransfer(d);
        }

        public void Dispose()
        {
            try { if (ctl != null) Command("QUIT"); } catch (Exception) { }
            CloseData(null);
            try { if (tcp != null) tcp.Close(); } catch (Exception) { }
        }
    }

    // ------------------------------------------------------------------------------------------
    // MIRROR (what the destination PC uses instead of robocopy)
    // ------------------------------------------------------------------------------------------
    public class FtpConn
    {
        public string Host;
        public int Port;
        public bool Tls;
        public string Pin;
        public string User;
        public string Pass;

        public FtpClient Open()
        {
            FtpClient c = new FtpClient(Host, Port, Tls, Pin);
            c.Connect();
            c.Login(User, Pass);
            return c;
        }
    }

    public class MirrorJob
    {
        public volatile bool Done;
        public bool Missing;                  // the remote folder does not exist
        public Exception Fatal;
        public long BytesDone;
        public long BytesTotal;
        public int FilesTotal;
        public int Copied, Skipped, Failed;
        public string Current = "";
        public List<string> Errors = new List<string>();
    }

    public static class FtpMirror
    {
        sealed class Item
        {
            public string Remote, Local;
            public long Size;
            public DateTime Mtime;
        }

        static bool SafeName(string n)
        {
            if (string.IsNullOrEmpty(n) || n == "." || n == "..") return false;
            return n.IndexOfAny(new char[] { '/', '\\', ':', '*', '?', '"', '<', '>', '|', '\0' }) < 0;
        }

        static bool InList(string[] list, string name)
        {
            if (list == null) return false;
            foreach (string s in list) { if (string.Equals(s, name, StringComparison.OrdinalIgnoreCase)) return true; }
            return false;
        }

        // Copies remoteRoot (recursively, or only the named files) into localRoot.
        // Existing local files are kept when they are newer, or equally old and the same size (robocopy /XO).
        public static MirrorJob Start(FtpConn conn, string remoteRoot, string localRoot, string[] files,
                                      string[] excludeDirs, string[] excludeFiles, int threads, bool dryRun)
        {
            MirrorJob job = new MirrorJob();
            Thread t = new Thread(delegate()
            {
                try { Run(job, conn, remoteRoot, localRoot, files, excludeDirs, excludeFiles, threads, dryRun); }
                catch (Exception ex) { job.Fatal = ex; }
                finally { job.Done = true; }
            });
            t.IsBackground = true;
            t.Start();
            return job;
        }

        static void AddError(MirrorJob job, string msg) { lock (job.Errors) { job.Errors.Add(msg); } }

        static void Run(MirrorJob job, FtpConn conn, string remoteRoot, string localRoot, string[] files,
                        string[] excludeDirs, string[] excludeFiles, int threads, bool dryRun)
        {
            List<Item> work = new List<Item>();
            using (FtpClient c0 = conn.Open())
            {
                c0.Progress = job;
                string rr = remoteRoot.TrimEnd('/');
                if (rr.Length == 0) rr = "/";
                Stack<KeyValuePair<string, string>> todo = new Stack<KeyValuePair<string, string>>();
                todo.Push(new KeyValuePair<string, string>(rr, localRoot));
                bool first = true;
                while (todo.Count > 0)
                {
                    KeyValuePair<string, string> cur = todo.Pop();
                    List<FtpEntry> list;
                    try { list = c0.List(cur.Key); }
                    catch (FtpException ex)
                    {
                        if (first && ex.Code == 550) { job.Missing = true; return; }
                        AddError(job, cur.Key + ": " + ex.Message); job.Failed++; continue;
                    }
                    first = false;
                    if (!dryRun) Directory.CreateDirectory(cur.Value);
                    foreach (FtpEntry e in list)
                    {
                        if (!SafeName(e.Name)) { AddError(job, cur.Key + ": skipped unsafe name"); job.Failed++; continue; }
                        string rp = (cur.Key == "/" ? "" : cur.Key) + "/" + e.Name;
                        string lp = Path.Combine(cur.Value, e.Name);
                        if (files != null)
                        {
                            if (e.IsDir || !InList(files, e.Name)) continue;
                        }
                        else if (e.IsDir)
                        {
                            if (!InList(excludeDirs, e.Name)) todo.Push(new KeyValuePair<string, string>(rp, lp));
                            continue;
                        }
                        else if (InList(excludeFiles, e.Name)) continue;

                        Item it = new Item();
                        it.Remote = rp; it.Local = lp; it.Size = e.Size; it.Mtime = e.ModifiedUtc;
                        FileInfo fi = new FileInfo(lp);
                        if (fi.Exists && it.Mtime.Year > 1980)
                        {
                            double diff = (fi.LastWriteTimeUtc - it.Mtime).TotalSeconds;
                            if (diff > 2 || (diff >= -2 && fi.Length == it.Size)) { job.Skipped++; continue; }
                        }
                        work.Add(it);
                        job.BytesTotal += it.Size;
                    }
                    if (files != null) break;       // named files live in the root folder only
                }
                job.FilesTotal = work.Count;
                if (dryRun) { job.Copied = work.Count; return; }
                if (work.Count == 0) return;

                int n = Math.Min(Math.Max(threads, 1), work.Count);
                int next = -1;
                List<Thread> pool = new List<Thread>();
                for (int w = 0; w < n; w++)
                {
                    FtpClient own = (w == 0) ? c0 : null;
                    Thread th = new Thread(delegate()
                    {
                        FtpClient fc = own;
                        try
                        {
                            while (true)
                            {
                                int idx = Interlocked.Increment(ref next);
                                if (idx >= work.Count) break;
                                Item it = work[idx];
                                job.Current = it.Remote;
                                string tmp = it.Local + ".wtt-part";
                                for (int attempt = 1; attempt <= 3; attempt++)
                                {
                                    try
                                    {
                                        if (fc == null) { fc = conn.Open(); fc.Progress = job; }
                                        Directory.CreateDirectory(Path.GetDirectoryName(it.Local));
                                        fc.Download(it.Remote, tmp, it.Size);
                                        if (it.Mtime.Year > 1980) File.SetLastWriteTimeUtc(tmp, it.Mtime);
                                        if (File.Exists(it.Local)) File.Delete(it.Local);
                                        File.Move(tmp, it.Local);
                                        Interlocked.Increment(ref job.Copied);
                                        break;
                                    }
                                    catch (Exception ex)
                                    {
                                        try { if (File.Exists(tmp)) File.Delete(tmp); } catch (Exception) { }
                                        if (fc != null && fc != own) { fc.Dispose(); }
                                        if (fc == own) { try { own.Dispose(); } catch (Exception) { } own = null; }
                                        fc = null;
                                        if (attempt == 3) { AddError(job, it.Remote + ": " + ex.Message); Interlocked.Increment(ref job.Failed); }
                                        else Thread.Sleep(500);
                                    }
                                }
                            }
                        }
                        finally { if (fc != null && fc != c0) { try { fc.Dispose(); } catch (Exception) { } } }
                    });
                    th.IsBackground = true;
                    pool.Add(th);
                    th.Start();
                }
                foreach (Thread th in pool) th.Join();
            }
        }
    }
}
