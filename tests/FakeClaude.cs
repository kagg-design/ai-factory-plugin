using System;
using System.IO;
using System.Text;

public static class FakeClaude
{
    private const string SessionId = "11111111-2222-4333-8444-555555555555";

    private static string Env(string name)
    {
        return Environment.GetEnvironmentVariable(name) ?? "";
    }

    private static bool Has(string[] args, string value)
    {
        foreach (string arg in args)
        {
            if (arg == value) return true;
        }
        return false;
    }

    private static string After(string[] args, string value)
    {
        for (int index = 0; index + 1 < args.Length; index++)
        {
            if (args[index] == value) return args[index + 1];
        }
        return "";
    }

    private static string Json(string value)
    {
        return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }

    private static int Increment(string path)
    {
        if (String.IsNullOrEmpty(path)) return 1;
        int count = 0;
        if (File.Exists(path)) Int32.TryParse(File.ReadAllText(path).Trim(), out count);
        count++;
        File.WriteAllText(path, count.ToString(), new UTF8Encoding(false));
        return count;
    }

    public static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--version")
        {
            string version = Env("CLAUDE_FACTORY_TEST_VERSION");
            if (String.IsNullOrEmpty(version)) version = "2.1.218";
            Console.WriteLine(version + " (Claude Code)");
            return 0;
        }

        if (args.Length > 0 && args[0] == "agents")
        {
            if (Env("CLAUDE_FACTORY_TEST_NO_AGENTS") == "1")
            {
                Console.WriteLine("[]");
                return 0;
            }
            string cwd = Json(Env("CLAUDE_FACTORY_TEST_AGENT_CWD"));
            string orchestratorSessionId = Env("CLAUDE_FACTORY_TEST_ORCHESTRATOR_SESSION_ID");
            if (!String.IsNullOrEmpty(orchestratorSessionId))
            {
                Console.WriteLine(
                    "[{\"id\":\"orch1234\",\"sessionId\":\"" + Json(orchestratorSessionId) +
                    "\",\"state\":\"blocked\",\"kind\":\"background\",\"name\":\"Claude Factory Orchestrator\",\"cwd\":\"" + cwd + "\",\"startedAt\":10}]"
                );
                return 0;
            }
            string status = Env("CLAUDE_FACTORY_TEST_AGENT_STATUS");
            if (String.IsNullOrEmpty(status)) status = "working";
            Console.WriteLine(
                "[{\"sessionId\":\"interactive-session\",\"status\":\"idle\",\"kind\":\"interactive\",\"name\":\"unrelated interactive session\",\"cwd\":\"" + cwd + "\"}," +
                "{\"id\":\"stale000\",\"sessionId\":\"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\",\"status\":\"stopped\",\"kind\":\"background\",\"name\":\"factory-test-task-test-task\",\"cwd\":\"" + cwd + "\",\"transcriptPath\":\"foreign-transcript\",\"lastAssistantMessage\":\"foreign\"}," +
                "{\"id\":\"test1234\",\"sessionId\":\"" + SessionId + "\",\"status\":\"" + status + "\",\"kind\":\"background\",\"name\":\"factory-test-task-test-task\",\"cwd\":\"" + cwd + "\",\"transcriptPath\":\"live-transcript\",\"lastAssistantMessage\":\"live\",\"startedAt\":1}]"
            );
            return 0;
        }

        if (args.Length > 0 && args[0] == "stop")
        {
            string stoppedId = args.Length > 1 ? args[1] : "";
            string stopFile = Env("CLAUDE_FACTORY_TEST_STOP_FILE");
            if (!String.IsNullOrEmpty(stopFile))
            {
                File.AppendAllText(stopFile, stoppedId + Environment.NewLine, new UTF8Encoding(false));
            }
            return 0;
        }

        if (args.Length > 0 && args[0] == "rm")
        {
            string removedId = args.Length > 1 ? args[1] : "";
            string rmFile = Env("CLAUDE_FACTORY_TEST_RM_FILE");
            if (!String.IsNullOrEmpty(rmFile))
            {
                File.WriteAllText(rmFile, removedId, new UTF8Encoding(false));
            }
            return Env("CLAUDE_FACTORY_TEST_RM_FAIL") == "1" ? 1 : 0;
        }

        if (args.Length > 0 && args[0] == "mcp")
        {
            Console.WriteLine("asana: connected");
            return 0;
        }

        string argvFile = Env("CLAUDE_FACTORY_TEST_ARGV_FILE");
        if (!String.IsNullOrEmpty(argvFile))
        {
            File.WriteAllLines(argvFile, args, new UTF8Encoding(false));
        }
        string promptCopy = Env("CLAUDE_FACTORY_TEST_PROMPT_COPY");
        string promptPath = Env("CLAUDE_FACTORY_PROMPT_PATH");
        if (!String.IsNullOrEmpty(promptCopy) && !String.IsNullOrEmpty(promptPath))
        {
            File.Copy(promptPath, promptCopy, true);
        }
        string systemPromptCopy = Env("CLAUDE_FACTORY_TEST_SYSTEM_PROMPT_COPY");
        string systemPromptPath = After(args, "--append-system-prompt-file");
        if (!String.IsNullOrEmpty(systemPromptCopy) && !String.IsNullOrEmpty(systemPromptPath))
        {
            File.Copy(systemPromptPath, systemPromptCopy, true);
        }

        int launchNumber = Increment(Env("CLAUDE_FACTORY_TEST_LAUNCH_COUNT_FILE"));
        string behavior = Env("CLAUDE_FACTORY_TEST_AGENT_BEHAVIOR");
        bool inline = Has(args, "--agents");
        bool systemPrompt = Has(args, "--append-system-prompt-file");
        bool fallback = Env("CLAUDE_FACTORY_TEST_MISSING_AGENT") == "1" ||
            behavior == "fallback-always" ||
            (behavior == "fallback-once" && !inline) ||
            (behavior == "fallback-to-system" && !systemPrompt) ||
            (behavior == "fallback-all-three" && !systemPrompt);
        bool systemFailure = systemPrompt && (
            behavior == "fallback-all-three" ||
            Env("CLAUDE_FACTORY_TEST_MISSING_AGENT") == "1"
        );
        string backgroundId = fallback || systemFailure ? "fallback" + launchNumber.ToString() : "test1234";
        if (fallback)
        {
            Console.Error.WriteLine(
                "Warning: agent " + After(args, "--agent") +
                " not found; using default agent template"
            );
        }
        Console.Error.WriteLine("Warning: benign background-launch warning");
        Console.WriteLine("backgrounded - " + backgroundId + " - factory-test-task");
        Console.WriteLine("claude attach " + backgroundId);
        if (systemFailure) return 1;
        return 0;
    }
}
