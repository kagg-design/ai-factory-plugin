[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$Port,
    [string]$HostName = "127.0.0.1"
)

$ErrorActionPreference = "Stop"
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse($HostName), $Port)
$listener.Start()
try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $body = "factory preview ok"
            $response = "HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body"
            $bytes = [Text.Encoding]::ASCII.GetBytes($response)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } catch {
            # Port probes can disconnect before reading the response.
        } finally {
            $client.Dispose()
        }
    }
} finally {
    $listener.Stop()
}
