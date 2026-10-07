--!strict
-- Tern's process API captures output but has no Windows no-console option.
-- Use the built-in Windows Script Host + PowerShell to create the dependency
-- process with CREATE_NO_WINDOW semantics, while keeping the same callback API.

local process = {}

local DATA = tern.plugin.data
local SEP = if tern.runtime.os == "windows" then "\\" else "/"
local REQUEST_PREFIX = DATA .. SEP .. "ytmusic-process-"
local RUNNER = DATA .. SEP .. "ytmusic-process.ps1"
local LAUNCHER = DATA .. SEP .. "ytmusic-process.vbs"

local PROCESS_SCRIPT = [=[
param([string]$RequestPath)
$ErrorActionPreference = 'Stop'
$resultPath = $RequestPath + '.result'
$status = 1
$timedOut = $false
$stdout = ''
$stderr = ''
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Quote-ProcessArgument([string]$value) {
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    $slashes = 0
    foreach ($character in $value.ToCharArray()) {
        if ($character -eq [char]92) {
            $slashes += 1
            continue
        }
        if ($character -eq [char]34) {
            for ($i = 0; $i -lt (2 * $slashes + 1); $i++) {
                [void]$builder.Append([char]92)
            }
            [void]$builder.Append([char]34)
        } else {
            for ($i = 0; $i -lt $slashes; $i++) {
                [void]$builder.Append([char]92)
            }
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    for ($i = 0; $i -lt (2 * $slashes); $i++) {
        [void]$builder.Append([char]92)
    }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

try {
    $request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = [string]$request.argv[0]
    $arguments = @()
    for ($i = 1; $i -lt $request.argv.Count; $i++) {
        $arguments += Quote-ProcessArgument ([string]$request.argv[$i])
    }
    $start.Arguments = $arguments -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    if ($request.cwd) {
        $start.WorkingDirectory = [string]$request.cwd
    }
    if ($request.env) {
        foreach ($entry in $request.env.PSObject.Properties) {
            $start.EnvironmentVariables[$entry.Name] = [string]$entry.Value
        }
    }

    $child = New-Object System.Diagnostics.Process
    $child.StartInfo = $start
    if (-not $child.Start()) {
        throw 'The dependency process did not start.'
    }
    $stdoutTask = $child.StandardOutput.ReadToEndAsync()
    $stderrTask = $child.StandardError.ReadToEndAsync()
    if ($null -ne $request.stdin -and [string]$request.stdin -ne '') {
        $child.StandardInput.Write([string]$request.stdin)
    }
    $child.StandardInput.Close()

    $limit = [int]$request.timeout_ms
    if ($limit -gt 0 -and -not $child.WaitForExit($limit)) {
        $timedOut = $true
        try { $child.Kill() } catch { }
    }
    $child.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($timedOut) {
        $status = -1
    } else {
        $status = $child.ExitCode
    }
    $child.Dispose()
} catch {
    $status = 1
    $stderr = $_.Exception.Message
}

$maxChars = 2000000
if ($stdout.Length -gt $maxChars) { $stdout = $stdout.Substring(0, $maxChars) }
if ($stderr.Length -gt $maxChars) { $stderr = $stderr.Substring(0, $maxChars) }
$response = @{ status = $status; stdout = $stdout; stderr = $stderr; timed_out = $timedOut }
$json = ConvertTo-Json -InputObject $response -Compress
    [System.IO.File]::WriteAllText($resultPath, $json, $utf8)
]=]

local LAUNCHER_SCRIPT = [=[
Option Explicit
Dim shell, powershell, runner, request, command
Set shell = CreateObject("WScript.Shell")
powershell = WScript.Arguments(0)
runner = WScript.Arguments(1)
request = WScript.Arguments(2)
command = Quote(powershell) & " -NoLogo -NoProfile -NonInteractive -File " & Quote(runner) & " " & Quote(request)
WScript.Quit shell.Run(command, 0, True)

Function Quote(value)
    Quote = Chr(34) & value & Chr(34)
End Function
]=]

local ready = false
local sequence = 0

local function ensure_runner(): ()
	if ready then
		return
	end
	tern.fs.write(RUNNER, PROCESS_SCRIPT)
	tern.fs.write(LAUNCHER, LAUNCHER_SCRIPT)
	ready = true
end

local function hidden_run(argv: { string }, opts: ProcessOptions?, done: (result: ProcessResult) -> ()): ()
	ensure_runner()
	sequence += 1
	local request_id = tostring(os.time()) .. "-" ..
		tostring(math.floor(tern.now() * 1000)) .. "-" ..
		tostring(sequence)
	local request_path = REQUEST_PREFIX .. request_id .. ".json"
	local result_path = request_path .. ".result"
	local request = {
		argv = argv,
		cwd = if opts == nil then nil else opts.cwd,
		env = if opts == nil then nil else opts.env,
		stdin = if opts == nil then nil else opts.stdin,
		timeout_ms = if opts == nil then nil else opts.timeout_ms,
	}
	tern.fs.write(request_path, tern.json.encode(request))

	local system_root = tern.getenv("SystemRoot") or "C:\\Windows"
	local powershell = system_root .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
	local outer_timeout = if opts ~= nil and opts.timeout_ms ~= nil and opts.timeout_ms > 0
		then opts.timeout_ms + 10000
		else nil
	tern.process.run({ system_root .. "\\System32\\wscript.exe", "//B", "//NoLogo", LAUNCHER, powershell, RUNNER, request_path }, {
		cwd = DATA,
		timeout_ms = outer_timeout,
	}, function(wrapper: ProcessResult, _cx)
		local ok, text = pcall(tern.fs.read, result_path, 16 * 1024 * 1024)
		pcall(tern.fs.remove, request_path)
		pcall(tern.fs.remove, result_path)
		if ok then
			local decoded_ok, response = pcall(tern.json.decode, text)
			if decoded_ok and type(response) == "table" and type(response.status) == "number" then
				done({
					status = response.status,
					stdout = if type(response.stdout) == "string" then response.stdout else "",
					stderr = if type(response.stderr) == "string" then response.stderr else "",
					timed_out = response.timed_out == true,
				})
				return
			end
		end
		done({
			status = wrapper.status,
			stdout = "",
			stderr = if wrapper.stderr ~= "" then wrapper.stderr else "Windows hidden process runner returned no result",
			timed_out = wrapper.timed_out,
		})
	end)
end

function process.run(argv: { string }, opts: ProcessOptions?, done: (result: ProcessResult) -> ()): ()
	if tern.runtime.os == "windows" then
		hidden_run(argv, opts, done)
		return
	end
	tern.process.run(argv, opts, function(result: ProcessResult, _cx)
		done(result)
	end)
end

return process
