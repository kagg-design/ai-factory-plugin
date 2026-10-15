using System;
using System.Threading;

internal static class FakeGh
{
    private static int Main(string[] args)
    {
        string mode = Environment.GetEnvironmentVariable("FACTORY_FAKE_GH_MODE") ?? "success";
        Thread.Sleep(mode == "timeout" ? 20000 : 5000);
        string sha = Environment.GetEnvironmentVariable("FACTORY_FAKE_GH_SHA") ?? new string('a', 40);
        string branch = Environment.GetEnvironmentVariable("FACTORY_FAKE_GH_BRANCH") ?? "develop";
        Console.WriteLine("{\"total_count\":1,\"workflow_runs\":[{\"id\":11,\"name\":\"CI\",\"head_sha\":\"" + sha +
            "\",\"head_branch\":\"" + branch + "\",\"event\":\"push\",\"run_attempt\":1,\"status\":\"completed\",\"conclusion\":\"success\"}]}");
        return 0;
    }
}
