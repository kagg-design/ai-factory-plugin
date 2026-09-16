using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

public static class FakeCodex
{
    private static string Escape(string value)
    {
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
    }

    private static string Extract(string input, string pattern, string fallback = "")
    {
        var match = Regex.Match(input, pattern);
        return match.Success ? match.Groups[1].Value : fallback;
    }

    private static void HandleAppServerLine(string line, Action<string> write)
    {
        var threadId = Environment.GetEnvironmentVariable("CLAUDE_FACTORY_TEST_CODEX_THREAD_ID") ??
            "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff";
        var repository = Environment.GetEnvironmentVariable("CLAUDE_FACTORY_REPOSITORY") ?? Directory.GetCurrentDirectory();
        var log = Environment.GetEnvironmentVariable("CLAUDE_FACTORY_TEST_CODEX_LOG");
        if (!String.IsNullOrEmpty(log))
            File.AppendAllText(log, "app-server-request\t" + line + Environment.NewLine, new UTF8Encoding(false));
        var method = Extract(line, "\\\"method\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"");
        var requestId = Extract(line, "\\\"id\\\"\\s*:\\s*(\\d+)");
        if (method == "initialized" || String.IsNullOrEmpty(requestId))
            return;
        var failMethod = Environment.GetEnvironmentVariable("CLAUDE_FACTORY_TEST_CODEX_APP_SERVER_FAIL_METHOD");
        if (!String.IsNullOrEmpty(failMethod) && method == failMethod)
        {
            write("{\"id\":" + requestId + ",\"error\":{\"code\":-32000,\"message\":\"injected app-server failure\"}}");
            return;
        }
        if (method == "initialize")
            write("{\"id\":" + requestId + ",\"result\":{\"serverInfo\":{\"name\":\"fake-codex\",\"version\":\"test\"}}}");
        else if (method == "remoteControl/enable")
            write("{\"id\":" + requestId + ",\"result\":{\"status\":\"connected\",\"serverName\":\"Fake Factory\",\"installationId\":\"fake-installation\",\"environmentId\":\"fake-environment\"}}");
        else if (method == "remoteControl/status/read")
            write("{\"id\":" + requestId + ",\"result\":{\"status\":\"connected\",\"serverName\":\"Fake Factory\"}}");
        else if (method == "project/list")
            write("{\"id\":" + requestId + ",\"result\":{\"data\":[{\"id\":\"test-project\",\"roots\":[{\"path\":\"" + Escape(repository) + "\"}]}],\"nextCursor\":null}}");
        else if (method == "thread/start")
            write("{\"id\":" + requestId + ",\"result\":{\"thread\":{\"id\":\"" + Escape(threadId) + "\"}}}");
        else if (method == "turn/start")
        {
            const string turnId = "dddddddd-eeee-4fff-8aaa-bbbbbbbbbbbb";
            write("{\"id\":" + requestId + ",\"result\":{\"turn\":{\"id\":\"" + turnId + "\",\"status\":\"inProgress\",\"items\":[]}}}");
            write("{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"" + Escape(threadId) + "\",\"turn\":{\"id\":\"" + turnId + "\",\"status\":\"completed\",\"items\":[]}}}");
        }
        else if (method == "thread/name/set" || method == "thread/archive")
            write("{\"id\":" + requestId + ",\"result\":{}}");
        else if (method == "thread/read")
            write("{\"id\":" + requestId + ",\"result\":{\"thread\":{\"id\":\"" + Escape(threadId) + "\"}}}");
        else
            write("{\"id\":" + requestId + ",\"error\":{\"code\":-32601,\"message\":\"unsupported fake method\"}}");
    }

    private static byte[] ReadExact(Stream stream, int count)
    {
        var result = new byte[count];
        var offset = 0;
        while (offset < count)
        {
            var read = stream.Read(result, offset, count - offset);
            if (read <= 0) throw new EndOfStreamException();
            offset += read;
        }
        return result;
    }

    private static string ReadWebSocketText(Stream stream)
    {
        var first = stream.ReadByte();
        if (first < 0) return null;
        var second = stream.ReadByte();
        if (second < 0) return null;
        var opcode = first & 0x0f;
        ulong length = (ulong)(second & 0x7f);
        if (length == 126)
        {
            var extended = ReadExact(stream, 2);
            length = (ulong)((extended[0] << 8) | extended[1]);
        }
        else if (length == 127)
        {
            var extended = ReadExact(stream, 8);
            length = 0;
            foreach (var value in extended) length = (length << 8) | value;
        }
        if (length > Int32.MaxValue) throw new InvalidDataException("Frame too large.");
        var mask = (second & 0x80) != 0 ? ReadExact(stream, 4) : null;
        var payload = ReadExact(stream, (int)length);
        if (mask != null)
            for (var index = 0; index < payload.Length; index++) payload[index] ^= mask[index % 4];
        if (opcode == 8) return null;
        if (opcode != 1) return String.Empty;
        return Encoding.UTF8.GetString(payload);
    }

    private static void WriteWebSocketText(Stream stream, string value)
    {
        var payload = Encoding.UTF8.GetBytes(value);
        stream.WriteByte(0x81);
        if (payload.Length < 126)
            stream.WriteByte((byte)payload.Length);
        else if (payload.Length <= UInt16.MaxValue)
        {
            stream.WriteByte(126);
            stream.WriteByte((byte)(payload.Length >> 8));
            stream.WriteByte((byte)payload.Length);
        }
        else
        {
            stream.WriteByte(127);
            for (var shift = 56; shift >= 0; shift -= 8) stream.WriteByte((byte)((ulong)payload.Length >> shift));
        }
        stream.Write(payload, 0, payload.Length);
        stream.Flush();
    }

    private static void ServeWebSocketClient(TcpClient client)
    {
        using (client)
        using (var stream = client.GetStream())
        {
            var headerBytes = new MemoryStream();
            var matched = 0;
            while (matched < 4)
            {
                var value = stream.ReadByte();
                if (value < 0) return;
                headerBytes.WriteByte((byte)value);
                var expected = new byte[] { 13, 10, 13, 10 };
                matched = value == expected[matched] ? matched + 1 : (value == 13 ? 1 : 0);
            }
            var headers = Encoding.ASCII.GetString(headerBytes.ToArray());
            var key = Extract(headers, "(?im)^Sec-WebSocket-Key:\\s*(\\S+)");
            using (var sha = SHA1.Create())
            {
                var accept = Convert.ToBase64String(sha.ComputeHash(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
                var response = Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n");
                stream.Write(response, 0, response.Length);
                stream.Flush();
            }
            while (true)
            {
                var line = ReadWebSocketText(stream);
                if (line == null) return;
                if (line.Length == 0) continue;
                HandleAppServerLine(line, value => WriteWebSocketText(stream, value));
            }
        }
    }

    private static int RunAppServer(string[] args)
    {
        var listenIndex = Array.IndexOf(args, "--listen");
        if (listenIndex >= 0 && listenIndex + 1 < args.Length && args[listenIndex + 1].StartsWith("ws://", StringComparison.OrdinalIgnoreCase))
        {
            var endpoint = new Uri(args[listenIndex + 1]);
            var listener = new TcpListener(IPAddress.Parse(endpoint.Host), endpoint.Port);
            listener.Start();
            while (true)
            {
                try { ServeWebSocketClient(listener.AcceptTcpClient()); }
                catch (IOException) { }
                catch (SocketException) { }
            }
        }
        string line;
        while ((line = Console.ReadLine()) != null)
        {
            HandleAppServerLine(line, value => { Console.WriteLine(value); Console.Out.Flush(); });
        }
        return 0;
    }

    public static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        var log = Environment.GetEnvironmentVariable("CLAUDE_FACTORY_TEST_CODEX_LOG");
        if (!String.IsNullOrEmpty(log))
            File.AppendAllText(log, String.Join("\t", args) + Environment.NewLine, new UTF8Encoding(false));

        if (args.Length == 1 && args[0] == "--version")
        {
            Console.WriteLine("codex-cli 0.148.0-test");
            return 0;
        }
        if (args.Contains("--help"))
        {
            if (args.Length >= 2 && args[0] == "exec" && args[1] == "resume")
                Console.WriteLine("Usage: codex exec resume [OPTIONS] [SESSION_ID] [PROMPT]");
            else if (args[0] == "exec")
                Console.WriteLine("Usage: codex exec [OPTIONS]\n      --json\n  -o, --output-last-message <FILE>");
            else if (args[0] == "resume")
                Console.WriteLine("Usage: codex resume [OPTIONS] [SESSION_ID]\n      --include-non-interactive");
            else if (args[0] == "app-server")
                Console.WriteLine("Usage: codex app-server [OPTIONS]\n      --stdio\n      --listen <URL>");
            else if (args[0] == "agents")
                Console.WriteLine("Usage: codex agents [OPTIONS]\n      --remote <ADDR>");
            else
                Console.WriteLine("fake help\n      --remote <ADDR>");
            return 0;
        }
        if (args.Length > 0 && args[0] == "app-server")
            return RunAppServer(args);
        if (args.Contains("--remote") && args.Contains("resume") &&
            args.Any(arg => new[] { "--approve-for-me", "--add-dir", "--sandbox", "-s",
                "--ask-for-approval", "-a", "--dangerously-bypass-approvals-and-sandbox" }.Contains(arg)))
        {
            Console.Error.WriteLine("Permission overrides are not supported when resuming a remote task.");
            return 1;
        }
        if (args.Length > 0 && (args[0] == "archive" || args[0] == "delete"))
            return 0;
        if (args.Length == 0 || args[0] != "exec")
            return 0;

        var prompt = Console.In.ReadToEnd();
        if (String.IsNullOrWhiteSpace(prompt) && args.Length > 1 && args[args.Length - 1] != "-")
            prompt = args[args.Length - 1];
        var taskMatches = Regex.Matches(prompt, "\\\"taskId\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"");
        var taskId = taskMatches.Count > 0 ? taskMatches[taskMatches.Count - 1].Groups[1].Value : "unknown-task";
        var orchestrator = prompt.IndexOf("Factory Orchestrator", StringComparison.OrdinalIgnoreCase) >= 0;
        var threadId = Environment.GetEnvironmentVariable("CLAUDE_FACTORY_TEST_CODEX_THREAD_ID") ??
            (orchestrator ? "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff" : "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee");
        var message = orchestrator
            ? "Factory Orchestrator is ready."
            : "FACTORY_PLAN\n{\"taskId\":\"" + Escape(taskId) + "\",\"understanding\":\"Inspect the requested change\",\"plan\":[\"Inspect code\",\"Implement after approval\"],\"questions\":[\"Proceed?\"],\"readyToImplement\":true}";
        var workerDelayText = Environment.GetEnvironmentVariable("CLAUDE_FACTORY_TEST_CODEX_WORKER_MILLISECONDS");
        var environmentCapture = Environment.GetEnvironmentVariable("CLAUDE_FACTORY_TEST_WORKER_ENV_CAPTURE");
        if (!String.IsNullOrEmpty(environmentCapture))
            File.WriteAllLines(environmentCapture, new[] {
                Environment.GetEnvironmentVariable("DB_DATABASE") ?? "",
                Environment.GetEnvironmentVariable("CLAUDE_FACTORY_TASK_ID") ?? "",
                Environment.GetEnvironmentVariable("CLAUDE_FACTORY_PROMPT_PATH") ?? "",
                Environment.GetEnvironmentVariable("DATABASE_URL") ?? ""
            }, new UTF8Encoding(false));
        int workerDelay;
        if (!orchestrator && Int32.TryParse(workerDelayText, out workerDelay) && workerDelay > 0)
            System.Threading.Thread.Sleep(workerDelay);
        var outputIndex = Array.IndexOf(args, "--output-last-message");
        if (outputIndex >= 0 && outputIndex + 1 < args.Length)
            File.WriteAllText(args[outputIndex + 1], message, new UTF8Encoding(false));

        Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"" + Escape(threadId) + "\"}");
        Console.WriteLine("{\"type\":\"turn.started\"}");
        Console.WriteLine("{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"" + Escape(message) + "\"}}");
        Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":{}}");
        return 0;
    }
}
