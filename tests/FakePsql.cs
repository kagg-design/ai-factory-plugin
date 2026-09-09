using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public static class FakePsql
{
    private static string Env(string name)
    {
        return Environment.GetEnvironmentVariable(name) ?? "";
    }

    private static HashSet<string> ReadDatabases(string path)
    {
        HashSet<string> databases = new HashSet<string>(StringComparer.Ordinal);
        if (String.IsNullOrEmpty(path) || !File.Exists(path)) return databases;
        foreach (string line in File.ReadAllLines(path))
        {
            string[] fields = line.Split('\t');
            if (fields.Length < 2) continue;
            if (fields[0] == "create") databases.Add(fields[1]);
            if (fields[0] == "drop") databases.Remove(fields[1]);
        }
        return databases;
    }

    private static void Append(string operation, string database)
    {
        string path = Env("CLAUDE_FACTORY_TEST_PSQL_REGISTRY_FILE");
        if (String.IsNullOrEmpty(path)) return;
        AppendWithRetry(path, operation + "\t" + database + Environment.NewLine);
    }

    private static void AppendWithRetry(string path, string text)
    {
        IOException failure = null;
        for (int attempt = 0; attempt < 200; attempt++)
        {
            try
            {
                File.AppendAllText(path, text, new UTF8Encoding(false));
                return;
            }
            catch (IOException exception)
            {
                failure = exception;
                Thread.Sleep(10);
            }
        }
        throw failure ?? new IOException("Could not append the fake PostgreSQL audit record.");
    }

    public static int Main(string[] args)
    {
        string sql = args.Length > 0 ? args[args.Length - 1] : "";
        Match nameMatch = Regex.Match(sql, @"(?:datname\s*=\s*'|CREATE\s+DATABASE\s+|DROP\s+DATABASE\s+)([a-z][a-z0-9_]*)", RegexOptions.IgnoreCase);
        string database = nameMatch.Success ? nameMatch.Groups[1].Value : "";
        string audit = Env("CLAUDE_FACTORY_TEST_PSQL_AUDIT_FILE");
        if (!String.IsNullOrEmpty(audit))
        {
            string passwordState = String.IsNullOrEmpty(Env("PGPASSWORD")) ? "missing-password" : "password-present";
            AppendWithRetry(audit, sql + "\t" + passwordState + Environment.NewLine);
        }

        string registry = Env("CLAUDE_FACTORY_TEST_PSQL_REGISTRY_FILE");
        HashSet<string> databases = ReadDatabases(registry);
        if (sql.StartsWith("SELECT CASE WHEN rolcreatedb", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine("1");
            return 0;
        }
        if (sql.StartsWith("SHOW server_version_num", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine("180000");
            return 0;
        }
        if (sql.StartsWith("SELECT 1", StringComparison.OrdinalIgnoreCase))
        {
            if (databases.Contains(database)) Console.WriteLine("1");
            return 0;
        }
        if (sql.StartsWith("CREATE DATABASE", StringComparison.OrdinalIgnoreCase))
        {
            if (databases.Contains(database)) return 1;
            Append("create", database);
            return 0;
        }
        if (sql.StartsWith("DROP DATABASE", StringComparison.OrdinalIgnoreCase))
        {
            if (Env("CLAUDE_FACTORY_TEST_PSQL_FAIL_DROP") == database) return 1;
            Append("drop", database);
            return 0;
        }
        return 2;
    }
}
