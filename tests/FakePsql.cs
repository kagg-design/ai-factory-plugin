using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

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
        File.AppendAllText(path, operation + "\t" + database + Environment.NewLine, new UTF8Encoding(false));
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
            File.AppendAllText(audit, sql + "\t" + passwordState + Environment.NewLine, new UTF8Encoding(false));
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
