using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

public static class FakeCodex
{
    private static string Escape(string value)
    {
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
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
            else
                Console.WriteLine("fake help");
            return 0;
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
