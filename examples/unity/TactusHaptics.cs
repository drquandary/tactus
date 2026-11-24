// Tactus haptics for Unity (macOS). Drop this file into Assets, then call for example:
//
//     TactusHaptics.Play("hit");
//     TactusHaptics.Play("explosion", 0.8f);
//     TactusHaptics.Hold("engine", hz, level);   // call every frame to keep it going
//
// Tactus must be running on the same Mac with the bridge module on (it is by default).

using System.Globalization;
using System.Net.Sockets;
using System.Text;

public static class TactusHaptics
{
    const int Port = 7477;
    static readonly UdpClient Udp = new UdpClient();

    static void Send(string line)
    {
        var bytes = Encoding.UTF8.GetBytes(line);
        try { Udp.Send(bytes, bytes.Length, "127.0.0.1", Port); } catch (SocketException) { /* Tactus not running */ }
    }

    static string F(float x) => x.ToString(CultureInfo.InvariantCulture);

    public static void Play(string pattern, float level = 1f) => Send($"play {pattern} {F(level)}");
    public static void Pulse(float hz, float ms, float level = 1f) => Send($"pulse {F(hz)} {F(ms)} {F(level)}");
    public static void Hold(string source, float hz, float level, float ttlMs = 150f) =>
        Send($"hold {source} {F(hz)} {F(level)} {F(ttlMs)}");
    public static void Release(string source) => Send($"release {source}");
}
