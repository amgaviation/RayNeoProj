// RayNeo companion bridge server.
//
// Listens for WebSocket connections from the web configurator and forwards each
// op to RayNeoWorkspaceApplier, which is where the actual NativeModule calls
// live. Also pushes head pose back so the browser previews can mirror what the
// glasses are doing.
//
// Deliberately small: a hand-rolled WebSocket handshake and frame codec, one
// connection at a time, no auth, no TLS. That is enough for tuning a workspace
// on a local network and nothing more.
//
// SECURITY: any client that can reach this port can change your display
// settings. Do not expose it beyond a network you trust, and do not ship it in a
// release build.
//
// Requires android.permission.INTERNET.

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using UnityEngine;

namespace RayNeo.Workspace
{
    public class BridgeServer : MonoBehaviour
    {
        [Tooltip("The applier that owns the panels and makes the SDK calls.")]
        public RayNeoWorkspaceApplier Applier;

        [Tooltip("TCP port to listen on. Must match the web app's Connect tab.")]
        public int Port = 8787;

        [Tooltip("Head pose updates pushed to the browser, per second. 0 disables.")]
        public float PoseHz = 20f;

        private TcpListener _listener;
        private Thread _acceptThread;
        private volatile bool _running;

        private TcpClient _client;
        private NetworkStream _stream;
        private readonly object _sendLock = new object();

        // Unity APIs are main-thread only, so socket reads queue work here and
        // Update() drains it.
        private readonly ConcurrentQueue<string> _inbound = new ConcurrentQueue<string>();
        private float _poseTimer;

        void Start()
        {
            if (Applier == null) Applier = GetComponent<RayNeoWorkspaceApplier>();
            _running = true;
            _acceptThread = new Thread(AcceptLoop) { IsBackground = true };
            _acceptThread.Start();
            Debug.Log("[BridgeServer] listening on port " + Port);
        }

        void OnDestroy()
        {
            _running = false;
            try { _listener?.Stop(); } catch { }
            try { _client?.Close(); } catch { }
        }

        // -------------------------------------------------------------------
        // Socket plumbing
        // -------------------------------------------------------------------

        void AcceptLoop()
        {
            try
            {
                _listener = new TcpListener(IPAddress.Any, Port);
                _listener.Start();
                while (_running)
                {
                    var client = _listener.AcceptTcpClient();
                    // One connection at a time: a second configurator would fight
                    // the first over the same device state.
                    try { _client?.Close(); } catch { }
                    _client = client;
                    _stream = client.GetStream();
                    if (!Handshake(_stream))
                    {
                        client.Close();
                        continue;
                    }
                    SendJson("{\"ev\":\"hello\",\"name\":\"rayneo-companion\",\"protocol\":1}");
                    ReadLoop(_stream);
                }
            }
            catch (Exception e)
            {
                if (_running) Debug.LogWarning("[BridgeServer] accept loop ended: " + e.Message);
            }
        }

        static bool Handshake(NetworkStream stream)
        {
            var buffer = new byte[4096];
            int read = stream.Read(buffer, 0, buffer.Length);
            if (read <= 0) return false;
            string request = Encoding.UTF8.GetString(buffer, 0, read);
            if (!Regex.IsMatch(request, "^GET", RegexOptions.IgnoreCase)) return false;

            var m = Regex.Match(request, "Sec-WebSocket-Key: (.*)");
            if (!m.Success) return false;
            string key = m.Groups[1].Value.Trim();

            // RFC 6455: SHA-1 of the key plus the fixed GUID, base64 encoded.
            string accept;
            using (var sha1 = SHA1.Create())
            {
                accept = Convert.ToBase64String(sha1.ComputeHash(
                    Encoding.UTF8.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
            }

            byte[] response = Encoding.UTF8.GetBytes(
                "HTTP/1.1 101 Switching Protocols\r\n" +
                "Connection: Upgrade\r\n" +
                "Upgrade: websocket\r\n" +
                "Sec-WebSocket-Accept: " + accept + "\r\n\r\n");
            stream.Write(response, 0, response.Length);
            return true;
        }

        void ReadLoop(NetworkStream stream)
        {
            var buffer = new byte[65536];
            while (_running && stream.CanRead)
            {
                int read;
                try { read = stream.Read(buffer, 0, buffer.Length); }
                catch { break; }
                if (read <= 0) break;

                int opcode = buffer[0] & 0x0F;
                if (opcode == 0x8) break;             // close
                if (opcode != 0x1 && opcode != 0x0) continue;  // text/continuation only

                bool masked = (buffer[1] & 0x80) != 0;
                long length = buffer[1] & 0x7F;
                int offset = 2;
                if (length == 126)
                {
                    length = (buffer[2] << 8) | buffer[3];
                    offset = 4;
                }
                else if (length == 127)
                {
                    length = 0;
                    for (int i = 0; i < 8; i++) length = (length << 8) | buffer[2 + i];
                    offset = 10;
                }

                // Browsers always mask client frames.
                byte[] mask = new byte[4];
                if (masked)
                {
                    Array.Copy(buffer, offset, mask, 0, 4);
                    offset += 4;
                }
                if (offset + length > read) continue;  // partial frame; skip it

                var payload = new byte[length];
                for (long i = 0; i < length; i++)
                {
                    payload[i] = masked
                        ? (byte)(buffer[offset + i] ^ mask[i % 4])
                        : buffer[offset + i];
                }
                _inbound.Enqueue(Encoding.UTF8.GetString(payload));
            }
        }

        void SendJson(string json)
        {
            var stream = _stream;
            if (stream == null || !stream.CanWrite) return;
            byte[] payload = Encoding.UTF8.GetBytes(json);
            var header = new List<byte> { 0x81 };  // FIN + text
            if (payload.Length <= 125)
            {
                header.Add((byte)payload.Length);
            }
            else if (payload.Length <= 65535)
            {
                header.Add(126);
                header.Add((byte)(payload.Length >> 8));
                header.Add((byte)(payload.Length & 0xFF));
            }
            else
            {
                header.Add(127);
                for (int i = 7; i >= 0; i--) header.Add((byte)((long)payload.Length >> (8 * i)));
            }
            try
            {
                lock (_sendLock)
                {
                    stream.Write(header.ToArray(), 0, header.Count);
                    stream.Write(payload, 0, payload.Length);
                    stream.Flush();
                }
            }
            catch { /* client vanished; the read loop will notice */ }
        }

        // -------------------------------------------------------------------
        // Main thread
        // -------------------------------------------------------------------

        void Update()
        {
            string frame;
            while (_inbound.TryDequeue(out frame)) Dispatch(frame);

            if (PoseHz > 0f && _stream != null)
            {
                _poseTimer += Time.deltaTime;
                if (_poseTimer >= 1f / PoseHz)
                {
                    _poseTimer = 0f;
                    PushPose();
                }
            }
        }

        void PushPose()
        {
            Quaternion q = NativeModule.Instance.GetGlassesQualternion();
            Vector3 e = q.eulerAngles;
            // Unity reports 0..360; the protocol uses signed degrees about zero.
            float yaw = Mathf.DeltaAngle(0f, e.y);
            float pitch = Mathf.DeltaAngle(0f, e.x);
            float roll = Mathf.DeltaAngle(0f, e.z);
            SendJson(string.Format(
                "{{\"ev\":\"pose\",\"yawDeg\":{0:F2},\"pitchDeg\":{1:F2},\"rollDeg\":{2:F2}}}",
                yaw, pitch, roll));
        }

        /// <summary>
        /// Route one op. Uses targeted string extraction rather than a JSON
        /// parser so the companion has no dependencies; `profile.apply` carries a
        /// whole nested document, which is the one case that needs real parsing.
        /// </summary>
        void Dispatch(string json)
        {
            string op = Str(json, "op");
            if (string.IsNullOrEmpty(op)) return;

            switch (op)
            {
                case "device.recenter":
                    Applier.Recenter();
                    break;

                case "device.setLuminance":
                    Applier.SetLuminance((int)Num(json, "mode", Applier.LuminanceMode));
                    break;

                case "device.setIpd":
                    Applier.SetIpd(Num(json, "ipdMm", Applier.IpdMm));
                    SendJson("{\"ev\":\"ipd\",\"ipdMm\":" + Applier.ReadIpd().ToString("F1") + "}");
                    break;

                case "device.changeFov":
                {
                    int scale = (int)Num(json, "scale", 0);
                    // The SDK applies ChangeFov as a relative nudge, so replay the
                    // delta from the last value rather than the absolute setting.
                    int delta = scale - Applier.FovScale;
                    if (delta != 0) NativeModule.Instance.ChangeFov(delta);
                    Applier.FovScale = scale;
                    break;
                }

                case "device.fovControlView":
                    Applier.ShowFovControlView = Bool(json, "active");
                    NativeModule.Instance.ActiveFovControlView(Applier.ShowFovControlView);
                    break;

                case "device.getIpd":
                    SendJson("{\"ev\":\"ipd\",\"ipdMm\":" + Applier.ReadIpd().ToString("F1") + "}");
                    break;

                case "view.activate":
                    Applier.ActivateView(Str(json, "viewId"));
                    break;

                case "panel.focus":
                    Applier.FocusPanel(Str(json, "panelId"));
                    break;

                case "device.setShade":
                case "device.setStereo":
                case "device.setRefreshRate":
                    // Recorded by the web app, but not settable through the SDK:
                    // shade is firmware, stereo and refresh rate come from the
                    // DisplayPort signal the host drives.
                    Log("ignored (not an SDK capability): " + op);
                    break;

                case "profile.apply":
                    // Needs a real JSON parser. Unity's JsonUtility cannot handle
                    // the nested arrays, so plug in your own (Newtonsoft, etc.) and
                    // rebuild the panels from it. For most workflows the baked
                    // export is simpler and this op is unnecessary.
                    Log("profile.apply received; use the baked Unity export instead");
                    break;

                default:
                    Log("unknown op: " + op);
                    break;
            }
        }

        void Log(string line)
        {
            Debug.Log("[BridgeServer] " + line);
            SendJson("{\"ev\":\"log\",\"line\":\"" + line.Replace("\"", "'") + "\"}");
        }

        // -------------------------------------------------------------------
        // Minimal field extraction
        // -------------------------------------------------------------------

        static string Str(string json, string key)
        {
            var m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*\"([^\"]*)\"");
            return m.Success ? m.Groups[1].Value : null;
        }

        static float Num(string json, string key, float fallback)
        {
            var m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*(-?[0-9]*\\.?[0-9]+)");
            float v;
            return m.Success && float.TryParse(m.Groups[1].Value, out v) ? v : fallback;
        }

        static bool Bool(string json, string key)
        {
            return Regex.IsMatch(json, "\"" + key + "\"\\s*:\\s*true");
        }
    }
}
