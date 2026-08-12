using System;
using System.Collections.Generic;
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

    private sealed class SessionRow
    {
        public string Id;
        public string SessionId;
        public string Cwd;
        public string Name;
        public string State;
        public bool HasPid;
        public string TranscriptPath;
    }

    private static void AppendEvent(string operation, params string[] values)
    {
        string path = Env("CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE");
        if (String.IsNullOrEmpty(path)) return;
        string[] fields = new string[values.Length + 1];
        fields[0] = operation;
        Array.Copy(values, 0, fields, 1, values.Length);
        File.AppendAllText(path, String.Join("\t", fields) + Environment.NewLine, new UTF8Encoding(false));
    }

    private static Dictionary<string, SessionRow> ReadSessions(string defaultCwd)
    {
        Dictionary<string, SessionRow> rows = new Dictionary<string, SessionRow>();
        rows["stale000"] = new SessionRow {
            Id = "stale000", SessionId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            Cwd = defaultCwd, Name = "factory-test-task-test-task", State = "stopped",
            TranscriptPath = "foreign-transcript"
        };
        rows["other999"] = new SessionRow {
            Id = "other999", SessionId = "99999999-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            Cwd = defaultCwd + "-other", Name = "factory-other-task-unrelated", State = "done",
            TranscriptPath = "other-transcript"
        };
        rows["orchestrator-static"] = new SessionRow {
            Id = "orchestrator-static", SessionId = "77777777-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            Cwd = defaultCwd, Name = "Claude Factory Orchestrator", State = "blocked", HasPid = true
        };

        string registry = Env("CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE");
        if (String.IsNullOrEmpty(registry) || !File.Exists(registry)) return rows;
        foreach (string line in File.ReadAllLines(registry))
        {
            string[] fields = line.Split('\t');
            if (fields.Length < 2) continue;
            string operation = fields[0];
            string id = fields[1];
            if (operation == "launch" && fields.Length >= 5)
            {
                rows[id] = new SessionRow {
                    Id = id,
                    SessionId = id == "test1234" ? SessionId : id + "-session",
                    Cwd = fields[2], Name = fields[3], State = fields[4],
                    TranscriptPath = id == "test1234" && !String.IsNullOrEmpty(Env("CLAUDE_FACTORY_TEST_TRANSCRIPT_PATH"))
                        ? Env("CLAUDE_FACTORY_TEST_TRANSCRIPT_PATH")
                        : (id == "test1234" ? "live-transcript" : id + "-transcript")
                };
            }
            else if (operation == "stop" && rows.ContainsKey(id))
            {
                rows[id].State = "stopped";
                rows[id].HasPid = false;
            }
            else if (operation == "rm")
            {
                rows.Remove(id);
            }
        }
        return rows;
    }

    private static string SessionJson(SessionRow row)
    {
        string pid = row.HasPid ? "\"pid\":4242," : "";
        string transcript = String.IsNullOrEmpty(row.TranscriptPath) ? "" :
            ",\"transcriptPath\":\"" + Json(row.TranscriptPath) + "\",\"lastAssistantMessage\":\"live\"";
        return "{" + pid + "\"id\":\"" + Json(row.Id) + "\",\"sessionId\":\"" +
            Json(row.SessionId) + "\",\"state\":\"" + Json(row.State) +
            "\",\"status\":\"" + Json(row.State) + "\",\"kind\":\"background\",\"name\":\"" +
            Json(row.Name) + "\",\"cwd\":\"" + Json(row.Cwd) + "\"" + transcript + "}";
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
            string rawCwd = Env("CLAUDE_FACTORY_TEST_AGENT_CWD");
            string cwd = Json(rawCwd);
            string orchestratorSessionId = Env("CLAUDE_FACTORY_TEST_ORCHESTRATOR_SESSION_ID");
            if (!String.IsNullOrEmpty(orchestratorSessionId))
            {
                Console.WriteLine(
                    "[{\"id\":\"orch1234\",\"sessionId\":\"" + Json(orchestratorSessionId) +
                    "\",\"state\":\"blocked\",\"kind\":\"background\",\"name\":\"Claude Factory Orchestrator\",\"cwd\":\"" + cwd + "\",\"startedAt\":10}]"
                );
                return 0;
            }
            Dictionary<string, SessionRow> sessions = ReadSessions(rawCwd);
            string status = Env("CLAUDE_FACTORY_TEST_AGENT_STATUS");
            string liveTerminalId = Env("CLAUDE_FACTORY_TEST_LIVE_TERMINAL_ID");
            List<string> jsonRows = new List<string>();
            jsonRows.Add("{\"sessionId\":\"interactive-session\",\"status\":\"idle\",\"kind\":\"interactive\",\"name\":\"unrelated interactive session\",\"cwd\":\"" + cwd + "\"}");
            foreach (SessionRow row in sessions.Values)
            {
                if (!String.IsNullOrEmpty(status) && row.Id == "test1234") row.State = status;
                if (row.Id == liveTerminalId && row.State != "stopped") { row.State = "done"; row.HasPid = true; }
                jsonRows.Add(SessionJson(row));
            }
            Console.WriteLine("[" + String.Join(",", jsonRows.ToArray()) + "]");
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
            if (Env("CLAUDE_FACTORY_TEST_STOP_FAIL_ID") == stoppedId) return 1;
            AppendEvent("stop", stoppedId);
            return 0;
        }

        if (args.Length > 0 && args[0] == "rm")
        {
            string removedId = args.Length > 1 ? args[1] : "";
            string rmFile = Env("CLAUDE_FACTORY_TEST_RM_FILE");
            if (!String.IsNullOrEmpty(rmFile))
            {
                File.AppendAllText(rmFile, removedId + Environment.NewLine, new UTF8Encoding(false));
            }
            string expectedPath = Env("CLAUDE_FACTORY_TEST_EXPECT_PATH_EXISTS_ON_RM");
            if (!String.IsNullOrEmpty(expectedPath) && !Directory.Exists(expectedPath)) return 2;
            bool fail = Env("CLAUDE_FACTORY_TEST_RM_FAIL") == "1" || Env("CLAUDE_FACTORY_TEST_RM_FAIL_ID") == removedId;
            if (!fail) AppendEvent("rm", removedId);
            return fail ? 1 : 0;
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
        if (Has(args, "--bg")) {
            string launchState = Env("CLAUDE_FACTORY_TEST_AGENT_STATUS");
            if (String.IsNullOrEmpty(launchState)) launchState = "working";
            AppendEvent("launch", backgroundId, Environment.CurrentDirectory, After(args, "--name"), launchState);
        }
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
