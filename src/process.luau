--!strict
-- Tern's process API captures output but has no Windows no-console option.
-- On Windows, compile and run a dedicated C# GUI-subsystem launcher (/target:winexe)
-- that starts console processes with CREATE_NO_WINDOW without visible windows,
-- falling back to Windows Script Host + PowerShell until compiled.

local process = {}

export type ProcessOptions = {
	cwd: string?,
	env: { [string]: string }?,
	stdin: string?,
	timeout_ms: number?,
}

export type ProcessResult = {
	status: number,
	stdout: string,
	stderr: string,
	timed_out: boolean,
}

local DATA = tern.plugin.data
local SEP = if tern.runtime.os == "windows" then "\\" else "/"
local REQUEST_PREFIX = DATA .. SEP .. "ytmusic-process-"
local RUNNER_PS = DATA .. SEP .. "ytmusic-process.ps1"
local LAUNCHER_VBS = DATA .. SEP .. "ytmusic-process.vbs"

-- Active requests in this VM to prevent cleanup from deleting them
local active_requests: { [string]: boolean } = {}

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
command = Quote(powershell) & " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File " & Quote(runner) & " " & Quote(request)
WScript.Quit shell.Run(command, 0, True)

Function Quote(value)
    Quote = Chr(34) & value & Chr(34)
End Function
]=]

local RUNNER_CS = [=[using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

class Runner {
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESSENTRY32 {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    static extern bool Process32First(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    static extern bool Process32Next(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool CloseHandle(IntPtr hObject);

    static void KillProcessTree(int pid) {
        var children = new List<int>();
        IntPtr snap = CreateToolhelp32Snapshot(0x00000002, 0);
        if (snap != IntPtr.Zero && snap.ToInt64() != -1) {
            try {
                var entry = new PROCESSENTRY32();
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
                if (Process32First(snap, ref entry)) {
                    do {
                        if (entry.th32ParentProcessID == (uint)pid) {
                            children.Add((int)entry.th32ProcessID);
                        }
                    } while (Process32Next(snap, ref entry));
                }
            } finally {
                CloseHandle(snap);
            }
        }
        foreach (int childPid in children) {
            KillProcessTree(childPid);
        }
        try {
            var proc = Process.GetProcessById(pid);
            if (!proc.HasExited) {
                proc.Kill();
            }
        } catch { }
    }

    static string QuoteArgument(string value) {
        if (string.IsNullOrEmpty(value)) return "\"\"";
        bool needsQuotes = false;
        for (int i = 0; i < value.Length; i++) {
            char c = value[i];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\"') {
                needsQuotes = true;
                break;
            }
        }
        if (!needsQuotes) return value;
        var sb = new StringBuilder();
        sb.Append('\"');
        int slashes = 0;
        for (int i = 0; i < value.Length; i++) {
            char c = value[i];
            if (c == '\\') {
                slashes++;
            } else if (c == '\"') {
                sb.Append('\\', 2 * slashes + 1);
                sb.Append('\"');
                slashes = 0;
            } else {
                sb.Append('\\', slashes);
                sb.Append(c);
                slashes = 0;
            }
        }
        sb.Append('\\', 2 * slashes);
        sb.Append('\"');
        return sb.ToString();
    }

    static int Main(string[] args) {
        if (args.Length < 2) return 1;
        int timeoutMs;
        if (!int.TryParse(args[0], out timeoutMs)) {
            timeoutMs = 0;
        }

        string targetProgram = args[1];
        var argBuilder = new StringBuilder();
        for (int i = 2; i < args.Length; i++) {
            if (i > 2) argBuilder.Append(' ');
            argBuilder.Append(QuoteArgument(args[i]));
        }

        var startInfo = new ProcessStartInfo();
        startInfo.FileName = targetProgram;
        startInfo.Arguments = argBuilder.ToString();
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        startInfo.RedirectStandardInput = true;
        startInfo.RedirectStandardOutput = true;
        startInfo.RedirectStandardError = true;

        Process child = new Process();
        child.StartInfo = startInfo;

        Stream cout = Console.OpenStandardOutput();
        Stream cerr = Console.OpenStandardError();

        try {
            if (!child.Start()) return 1;
        } catch (Exception ex) {
            byte[] errBytes = Encoding.UTF8.GetBytes(ex.Message + "\n");
            try { cerr.Write(errBytes, 0, errBytes.Length); cerr.Flush(); } catch { }
            return 1;
        }

        var stdinThread = new Thread(() => {
            try {
                using (Stream cin = Console.OpenStandardInput())
                using (Stream pin = child.StandardInput.BaseStream) {
                    byte[] buf = new byte[8192];
                    int r;
                    while ((r = cin.Read(buf, 0, buf.Length)) > 0) {
                        pin.Write(buf, 0, r);
                        pin.Flush();
                    }
                }
            } catch { }
            try { child.StandardInput.Close(); } catch { }
        });
        stdinThread.IsBackground = true;
        stdinThread.Start();

        var stdoutThread = new Thread(() => {
            try {
                using (Stream pout = child.StandardOutput.BaseStream) {
                    byte[] buf = new byte[8192];
                    int r;
                    while ((r = pout.Read(buf, 0, buf.Length)) > 0) {
                        cout.Write(buf, 0, r);
                    }
                    cout.Flush();
                }
            } catch { }
        });
        stdoutThread.IsBackground = true;
        stdoutThread.Start();

        var stderrThread = new Thread(() => {
            try {
                using (Stream perr = child.StandardError.BaseStream) {
                    byte[] buf = new byte[8192];
                    int r;
                    while ((r = perr.Read(buf, 0, buf.Length)) > 0) {
                        cerr.Write(buf, 0, r);
                    }
                    cerr.Flush();
                }
            } catch { }
        });
        stderrThread.IsBackground = true;
        stderrThread.Start();

        bool timedOut = false;
        if (timeoutMs > 0) {
            if (!child.WaitForExit(timeoutMs)) {
                timedOut = true;
                KillProcessTree(child.Id);
            }
        }

        child.WaitForExit();
        stdoutThread.Join(1000);
        stderrThread.Join(1000);
        try { cout.Flush(); } catch { }
        try { cerr.Flush(); } catch { }

        if (timedOut) return -1;
        return child.ExitCode;
    }
}
]=]

local function compute_hash(src: string): string
	local h = 5381
	for i = 1, #src do
		h = (h * 33 + string.byte(src, i)) % 4294967296
	end
	return string.format("%08x", h)
end

local RUNNER_HASH = compute_hash(RUNNER_CS)
local RUNNER_EXE = DATA .. SEP .. "tern-runner-" .. RUNNER_HASH .. ".exe"
local RUNNER_CS_PATH = DATA .. SEP .. "tern-runner-" .. RUNNER_HASH .. ".cs"

local ps_ready = false
local sequence = 0

local function ensure_ps_runner(): ()
	if ps_ready then
		return
	end
	tern.fs.write(RUNNER_PS, PROCESS_SCRIPT)
	tern.fs.write(LAUNCHER_VBS, LAUNCHER_SCRIPT)
	ps_ready = true
end

local function hidden_run(argv: { string }, opts: ProcessOptions?, done: (result: ProcessResult) -> ()): ()
	ensure_ps_runner()
	sequence += 1
	local request_id = tostring(os.time()) .. "-" .. tostring(math.floor(tern.now() * 1000)) .. "-" .. tostring(sequence)
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
	active_requests[request_id] = true

	local system_root = tern.getenv("SystemRoot") or tern.getenv("WINDIR") or "C:\\Windows"
	local powershell = system_root .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
	local outer_timeout = if opts ~= nil and opts.timeout_ms ~= nil and opts.timeout_ms > 0
		then opts.timeout_ms + 10000
		else nil

	tern.process.run(
		{ system_root .. "\\System32\\wscript.exe", "//B", "//NoLogo", LAUNCHER_VBS, powershell, RUNNER_PS, request_path },
		{
			cwd = DATA,
			timeout_ms = outer_timeout,
		},
		function(wrapper: ProcessResult, _cx)
			active_requests[request_id] = nil
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
				stderr = if wrapper.stderr ~= ""
					then wrapper.stderr
					else "Windows hidden process runner returned no result",
				timed_out = wrapper.timed_out,
			})
		end
	)
end

local compile_attempted = false
local compile_in_progress = false
local compile_succeeded = false
-- Set when the built runner failed to start; the VM then stays on PowerShell.
local runner_broken = false

local function check_runner_compiled(): boolean
	-- While csc runs, the exe may exist half-written.
	if runner_broken or compile_in_progress then
		return false
	end
	if compile_succeeded then
		return true
	end
	local ok, exists = pcall(tern.fs.exists, RUNNER_EXE)
	if ok and exists then
		compile_succeeded = true
		return true
	end
	return false
end

local function trigger_compile(): ()
	if compile_attempted or compile_in_progress then
		return
	end
	compile_attempted = true
	compile_in_progress = true

	local system_root = tern.getenv("SystemRoot") or tern.getenv("WINDIR") or "C:\\Windows"
	local csc64 = system_root .. "\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe"
	local csc32 = system_root .. "\\Microsoft.NET\\Framework\\v4.0.30319\\csc.exe"
	local csc_path: string? = nil
	local ok64, exists64 = pcall(tern.fs.exists, csc64)
	if ok64 and exists64 then
		csc_path = csc64
	else
		local ok32, exists32 = pcall(tern.fs.exists, csc32)
		if ok32 and exists32 then
			csc_path = csc32
		end
	end

	if csc_path == nil then
		compile_in_progress = false
		tern.log.warn("Windows runner: csc.exe not found")
		return
	end

	local write_ok = pcall(tern.fs.write, RUNNER_CS_PATH, RUNNER_CS)
	if not write_ok then
		compile_in_progress = false
		tern.log.warn("Windows runner: failed to write source file")
		return
	end

	hidden_run({
		csc_path,
		"/target:winexe",
		"/nologo",
		"/optimize+",
		"/out:" .. RUNNER_EXE,
		RUNNER_CS_PATH,
	}, { timeout_ms = 30000 }, function(result: ProcessResult)
		compile_in_progress = false
		pcall(tern.fs.remove, RUNNER_CS_PATH)
		if result.status == 0 and check_runner_compiled() then
			compile_succeeded = true
		else
			tern.log.warn("Windows runner compilation failed: " .. result.stderr)
		end
	end)
end

function process.cleanup(): ()
	local ok, entries = pcall(tern.fs.list, DATA)
	if not ok or type(entries) ~= "table" then
		return
	end
	for _, entry in entries do
		if string.sub(entry, 1, 16) == "ytmusic-process-" then
			local in_use = false
			for req_id in active_requests do
				if string.find(entry, req_id, 1, true) ~= nil then
					in_use = true
					break
				end
			end
			if not in_use then
				pcall(tern.fs.remove, DATA .. SEP .. entry)
			end
		end
	end
end

-- Start building the Windows runner right away; until it exists, processes
-- go through the PowerShell path. (Stale files are swept by the host,
-- deferred, through `process.cleanup`.)
if tern.runtime.os == "windows" and not check_runner_compiled() then
	trigger_compile()
end

function process.run(argv: { string }, opts: ProcessOptions?, done: (result: ProcessResult) -> ()): ()
	if tern.runtime.os == "windows" then
		if check_runner_compiled() then
			local timeout_val = if opts ~= nil and opts.timeout_ms ~= nil and opts.timeout_ms > 0
				then opts.timeout_ms
				else 0
			local runner_argv: { string } = {
				RUNNER_EXE,
				tostring(timeout_val),
			}
			for _, arg in argv do
				table.insert(runner_argv, arg)
			end
			local outer_timeout = if timeout_val > 0 then timeout_val + 10000 else nil
			local started = pcall(tern.process.run, runner_argv, {
				cwd = if opts ~= nil then opts.cwd else nil,
				env = if opts ~= nil then opts.env else nil,
				stdin = if opts ~= nil then opts.stdin else nil,
				timeout_ms = outer_timeout,
			}, function(result: ProcessResult, _cx)
				local timed_out = result.timed_out
					or (timeout_val > 0 and (result.status == -1 or result.status == 4294967295))
				done({
					status = if timed_out then -1 else result.status,
					stdout = result.stdout,
					stderr = result.stderr,
					timed_out = timed_out,
				})
			end)
			if started then
				return
			end
			-- The runner would not start (quarantined, deleted): stop using it.
			runner_broken = true
			compile_attempted = true
			tern.log.warn("ytmusic: the Windows runner did not start; using PowerShell")
			hidden_run(argv, opts, done)
			return
		end

		-- Not compiled yet or compilation failed: use hidden PowerShell runner
		if not compile_attempted then
			trigger_compile()
		end
		hidden_run(argv, opts, done)
		return
	end

	tern.process.run(argv, opts, function(result: ProcessResult, _cx)
		done(result)
	end)
end

return process
