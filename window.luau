--!strict
-- The window half. One window at a time (a lease in kv) collects every agent
-- block (`cx.agents`), asks a small model for a status card of each idle one
-- and publishes the board under kv `board`; the host's `board` block draws it.
-- Every window serves the `tern-sessions://` links the block's buttons open:
-- reveal a session's pane, reply to it, close it, summarize it again.
--
-- Background jobs (async bash, eval, subagents) come from each omp's session
-- file (`tern inspect` names it): a tool result with `details.async.state =
-- "running"` starts one; an `async-result` delivery, a cancel, a `wait` that
-- saw it end or the omp exiting (`session_exit`) ends it.

local KIND = "session-manager.board"
local LINK = "tern-sessions://"
local MODEL = "anthropic/claude-haiku-4-5"
local CONCURRENCY = 2
local SUMMARY_TIMEOUT_MS = 180000
local TICK_MS = 10000
-- A turn's end often comes in a burst of state changes: summarize once it settles.
local SETTLE_MS = 3000
local LEASE_S = 45
-- Transcript digest limits (characters).
local USER_CHARS = 800
local RECENT_CHARS = 3000
local OLD_CHARS = 300
local RECENT_MESSAGES = 10
local DIGEST_CHARS = 60000

local HOME = tern.getenv("HOME") or ""
-- Windows started from the Dock have a PATH without these directories.
local OMP = {
	HOME .. "/Library/Application Support/Tern/omp/bin/omp",
	HOME .. "/.bun/bin/omp",
	HOME .. "/.local/bin/omp",
	"/opt/homebrew/bin/omp",
	"/usr/local/bin/omp",
}
local PATH = table.concat({
	HOME .. "/.local/bin",
	HOME .. "/.bun/bin",
	"/opt/homebrew/bin",
	"/usr/local/bin",
	"/usr/bin",
	"/bin",
	"/usr/sbin",
	"/sbin",
}, ":")
local TERN = { "/Applications/Tern.app/Contents/MacOS/tern", HOME .. "/.local/bin/tern", "/opt/homebrew/bin/tern" }
-- Only the session-file lines that start or end background jobs.
local JOB_LINES =
	[["async":\{"state"|"customType":"(async-result|session_exit|tool_execution_start)"|Cancelled background job|"toolName":"wait"]]

local STATE_MEANING: { [string]: string } = {
	working = "the agent is running a turn now",
	waiting_input = "the agent shows a question or a permission request and waits for the user",
	idle = "the agent finished its last turn and waits for a new prompt",
	exited = "the agent program stopped; the pane is still open",
}

local INSTRUCTIONS = [[
You read the transcript of a coding-agent session. Write a status card for the person who runs the session.

Write every text value in ASD-STE100 Simplified Technical English:
- Use simple approved words. Use one topic in each sentence.
- Use a maximum of 20 words in an instruction and 25 words in a description.
- Use the active voice. Use the imperative for instructions. Use the present or past tense.
- Do not use idioms, slang or filler words.
- Keep names, PR numbers, branch names, file names and commands exact. Put them in backticks.
- Use the articles "the" and "a". Do not omit them.
- Count the words. Make two sentences from a long sentence.

The answers the user gave to the agent's questions show under `ask` tool lines. The agent's latest task list shows under a `todo` tool line. The background jobs that run now show in the "Running background jobs" list. When the agent waits for one of them, "waiting_on" is "agent" and the status tells which job it waits for.

Reply with one JSON object and nothing else (no code fence). Keys:
- "purpose": one sentence. The overall goal of the session.
- "status": a maximum of three sentences. What is done and what occurs now.
- "waiting_on": "you" (the user), "agent" (the agent works), "external" (CI, a review, a deploy, another person) or "nothing".
- "needs_you": true only when the session stops now until the user acts: a question, a decision, an approval or a manual step. A future step for the user is a todo, not a reason for true.
- "why": when "needs_you" is true, one sentence that tells what the user must do and why. Else "".
- "todo": a list of instructions. The tasks to complete before the user can close this session (for example: merge the PR, do a review, deploy, verify, delete the worktree). Use an empty list when no task remains.
- "can_close": true when no task remains and no background job runs.
- "jobs": one entry for each running background job, in the same order: {"id": the job id, "purpose": one or two sentences that tell what the job does and why the session needs it, "next": one sentence that tells what occurs with its result}. Use an empty list when no job runs.
]]

type Summary = {
	fp: string?,
	at: number,
	purpose: string?,
	status: string?,
	waiting_on: string?,
	needs_you: boolean?,
	why: string?,
	todo: { string }?,
	can_close: boolean?,
	jobs: { { id: string, purpose: string, next: string } }?,
	error: string?,
}

-- In-flight summaries and the queue, by pane key (this VM only).
local jobs: { [string]: boolean } = {}
local queue: { { key: string, pane: number, fp: string } } = {}
-- Panes the user asked to summarize again, whatever their state.
local forced: { [string]: boolean } = {}
-- The pane focused before the board, for the toggle back.
local last_focus: number? = nil
local settle: TimerHandle? = nil

-- A background job that runs in an omp session.
type Job = {
	id: string,
	-- bash, eval or task.
	type: string,
	-- The tool call's intent, else the subagent id.
	label: string,
	-- A bash job's command, a subagent's assignment (clipped).
	detail: string,
	-- Start, in epoch seconds.
	at: number?,
}
-- Each omp pane's session file, from `tern inspect`, and its running jobs (by pane key).
local session_files: { [string]: string } = {}
local bg: { [string]: { Job } } = {}
local scanning = false

local function find(candidates: { string }): string?
	for _, c in candidates do
		if tern.fs.exists(c) then
			return c
		end
	end
	return nil
end

-- Pane ids pass 2^31: format them without an exponent.
local function key_of(pane: number): string
	return string.format("%.0f", pane)
end

local function clip(s: string, n: number): string
	if #s <= n then
		return s
	end
	return string.sub(s, 1, n) .. " […]"
end

local function str(v: any): string
	return if type(v) == "string" then v else ""
end

local function first_line(s: string): string
	return string.match(s, "[^\n]+") or s
end

local function url_decode(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end))
end

local function query(url: string): { [string]: string }
	local out: { [string]: string } = {}
	local q = string.match(url, "%?(.*)$") or ""
	for k, v in string.gmatch(q, "([^&=]+)=([^&]*)") do
		out[k] = url_decode(v)
	end
	return out
end

local function load_summaries(): { [string]: Summary }
	local s = tern.kv.get("summaries")
	return if type(s) == "table" then s else {}
end

-- Leadership: the window that collects and summarizes. Another window takes over
-- once the leader stops renewing (closed, reloaded elsewhere).
local function lead(cx: WindowCx, claim: boolean?): boolean
	local me = cx:window_key()
	local l = tern.kv.get("leader")
	local now = os.time()
	local free = type(l) ~= "table" or now - (tonumber(l.at) or 0) > LEASE_S
	if claim or free or l.window == me then
		if claim or free or l.window ~= me or now - (tonumber(l.at) or 0) > 10 then
			tern.kv.set("leader", { window = me, at = now })
		end
		return true
	end
	return false
end

-- The board block on screen in this window, if any.
local function board_pane(cx: WindowCx): number?
	for _, p in cx.session:panes() do
		if p.block == KIND then
			return p.pane
		end
	end
	return nil
end

-- Shows `pane` wherever it is: its session, its tab, out of the deck.
local function reveal(cx: WindowCx, pane: number): boolean
	local info = cx.session:pane(pane)
	if not info then
		return false
	end
	if info.parked then
		cx.layout:unpark(pane)
	end
	local tab = cx.session:tab_of(pane)
	if tab then
		for _, s in cx.session:sessions() do
			if not s.current and table.find(s.tabs, tab) then
				cx.sessions:switch(s.id)
				break
			end
		end
	end
	cx.layout:focus(pane)
	return true
end

-- Transcript ---------------------------------------------------------------

-- Tools whose text the summary needs: the user's answers and the agent's task list.
local TOOL_TEXT: { [string]: number } = { ask = 1000, ask_user_question = 1000, quiz = 600, todo = 1500 }

local function tool_line(t: { [string]: any }): string
	local name = str(t.name)
	local what = str(t.intent)
	if what == "" then
		what = first_line(str(t.target))
	end
	local line = "  - " .. name .. ": " .. clip(what, 120)
	local status = str(t.status)
	if status ~= "" and status ~= "done" then
		line ..= " (" .. status .. ")"
	end
	local keep = TOOL_TEXT[name]
	if keep and str(t.text) ~= "" then
		line ..= "\n    " .. string.gsub(clip(t.text, keep), "\n", "\n    ")
	end
	return line
end

-- The conversation as text: every user message, the last assistant replies in
-- full, older ones cut short, one line per tool call (its intent), the user's
-- answers to `ask` and the latest todo list; the oldest replies go first past
-- DIGEST_CHARS.
local function digest(messages: { AgentMessage }): string
	local recent_from = 0
	local seen = 0
	for i = #messages, 1, -1 do
		if messages[i].role == "assistant" then
			seen += 1
			if seen == RECENT_MESSAGES then
				recent_from = i
				break
			end
		end
	end
	local last_todo: any = nil
	for i = #messages, 1, -1 do
		for _, t in messages[i].tools or {} do
			if t.name == "todo" then
				last_todo = t
			end
		end
		if last_todo then
			break
		end
	end
	local parts: { string } = {}
	local total = 0
	for i, m in messages do
		local text = string.match(m.text, "^%s*(.-)%s*$") or ""
		local lines: { string } = {}
		if m.role == "user" then
			table.insert(lines, "USER: " .. clip(text, USER_CHARS))
		else
			table.insert(lines, "AGENT:" .. (if text ~= "" then " " .. clip(text, if i >= recent_from then RECENT_CHARS else OLD_CHARS) else ""))
			for _, t in m.tools or {} do
				-- Only the latest todo list counts.
				if t.name ~= "todo" or t == last_todo then
					table.insert(lines, tool_line(t))
				end
			end
		end
		if #lines > 1 or text ~= "" then
			local part = table.concat(lines, "\n")
			table.insert(parts, part)
			total += #part
		end
	end
	-- Drop the oldest agent replies until it fits.
	local i = 1
	while total > DIGEST_CHARS and i <= #parts do
		if string.sub(parts[i], 1, 6) == "AGENT:" then
			total -= #parts[i]
			parts[i] = "AGENT: […]"
		end
		i += 1
	end
	return table.concat(parts, "\n\n")
end

local function ago_text(at: number?): string
	if not at then
		return "unknown"
	end
	local m = (os.time() - at) // 60
	return if m < 1 then "less than a minute ago" else string.format("%d minutes ago", m)
end

local function prompt_for(a: AgentBlock, title: string, conversation: string, running: { Job }): string
	local job_lines: { string } = {}
	for _, j in running do
		table.insert(
			job_lines,
			string.format("- %s (%s, started %s): %s\n  %s", j.id, j.type, ago_text(j.at), j.label, j.detail)
		)
	end
	return INSTRUCTIONS
		.. "\nSession title: "
		.. title
		.. "\nDirectory: "
		.. a.cwd
		.. "\nTern state: "
		.. a.state
		.. " ("
		.. (STATE_MEANING[a.state] or "unknown")
		.. ")\n\nRunning background jobs:\n"
		.. (if #job_lines > 0 then table.concat(job_lines, "\n") else "none")
		.. "\n\nThe transcript is between <transcript> and </transcript>. When it has no user message, the session has no work: write \"The session has no messages.\" as the status.\n\n<transcript>\n"
		.. conversation
		.. "\n</transcript>\n"
end

-- The first `{` to the last `}` of the reply, decoded.
local function parse(stdout: string): any
	local from = string.find(stdout, "{", 1, true)
	local to: number? = nil
	for i = #stdout, 1, -1 do
		if string.sub(stdout, i, i) == "}" then
			to = i
			break
		end
	end
	if not from or not to or to < from then
		return nil
	end
	local ok, value = pcall(tern.json.decode, string.sub(stdout, from, to))
	return if ok and type(value) == "table" then value else nil
end

local function to_summary(fp: string, d: any): Summary
	local todo: { string } = {}
	if type(d.todo) == "table" then
		for _, t in d.todo do
			if type(t) == "string" and t ~= "" then
				table.insert(todo, t)
			end
		end
	end
	local notes: { { id: string, purpose: string, next: string } } = {}
	if type(d.jobs) == "table" then
		for _, j in d.jobs do
			if type(j) == "table" and str(j.id) ~= "" then
				table.insert(notes, { id = str(j.id), purpose = str(j.purpose), next = str(j.next) })
			end
		end
	end
	return {
		fp = fp,
		at = os.time(),
		purpose = str(d.purpose),
		status = str(d.status),
		waiting_on = str(d.waiting_on),
		needs_you = d.needs_you == true,
		why = str(d.why),
		todo = tern.json.array(todo),
		can_close = d.can_close == true,
		jobs = tern.json.array(notes),
	}
end

-- Background jobs ----------------------------------------------------------

local UTC_OFFSET = os.time() - os.time(os.date("!*t") :: any)

-- `2026-11-18T19:09:15.715Z` in epoch seconds.
local function epoch(iso: any): number?
	local y, mo, d, h, mi, s = string.match(str(iso), "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then
		return nil
	end
	return os.time({
		year = tonumber(y) :: number,
		month = tonumber(mo) :: number,
		day = tonumber(d) :: number,
		hour = tonumber(h) :: number,
		min = tonumber(mi) :: number,
		sec = tonumber(s) :: number,
	}) + UTC_OFFSET
end

local function text_of(content: any): string
	if type(content) == "string" then
		return content
	end
	local parts: { string } = {}
	for _, p in (if type(content) == "table" then content else {}) :: { any } do
		if type(p) == "table" and type(p.text) == "string" then
			table.insert(parts, p.text)
		end
	end
	return table.concat(parts, "\n")
end

-- A subagent assignment's first line of substance.
local function assignment(task: string): string
	for line in string.gmatch(task, "[^\n]+") do
		local l = string.match(line, "^%s*(.-)%s*$") or ""
		if l ~= "" and not string.match(l, "^#") and not string.match(l, "^Complete assignment") then
			return clip(l, 240)
		end
	end
	return ""
end

-- The jobs still running at the end of `lines` (the session file's JOB_LINES), oldest first.
local function running_jobs(lines: string): { Job }
	local running: { [string]: Job } = {}
	local starts: { [string]: any } = {}
	for line in string.gmatch(lines, "[^\n]+") do
		local ok, e = pcall(tern.json.decode, line)
		if not ok or type(e) ~= "table" then
			continue
		end
		if e.type == "custom" and e.customType == "tool_execution_start" and type(e.data) == "table" then
			starts[str(e.data.toolCallId)] = e.data
		elseif e.type == "custom" and e.customType == "session_exit" then
			-- The omp exited: its jobs went with it.
			running = {}
		elseif e.type == "custom_message" and e.customType == "async-result" then
			local d = e.details
			for _, j in (if type(d) == "table" and type(d.jobs) == "table" then d.jobs else {}) :: { any } do
				running[str(j.jobId)] = nil
			end
		elseif e.type == "message" and type(e.message) == "table" and e.message.role == "toolResult" then
			local m = e.message
			local d = if type(m.details) == "table" then m.details else {}
			local async = d.async
			if type(async) == "table" and async.state == "running" then
				local start = starts[str(m.toolCallId)]
				local intent = if type(start) == "table" then str(start.intent) else ""
				local args = if type(start) == "table" and type(start.args) == "table" then start.args else {}
				if type(d.progress) == "table" and #d.progress > 0 then
					for _, p in d.progress do
						local id = str(p.id)
						running[id] = {
							id = id,
							type = "task",
							label = if str(p.agent) ~= "" then str(p.agent) .. " subagent" else "subagent",
							detail = assignment(str(p.task)),
							at = epoch(e.timestamp),
						}
					end
				else
					local id = str(async.jobId)
					running[id] = {
						id = id,
						type = str(async.type),
						label = if intent ~= "" then intent else id,
						detail = clip(first_line(str(args.command or args.code)), 240),
						at = epoch(e.timestamp),
					}
				end
			elseif type(async) == "table" and (async.state == "completed" or async.state == "failed") then
				running[str(async.jobId)] = nil
			end
			local t = text_of(m.content)
			for id in string.gmatch(t, "Cancelled background job ([^%s]-)%.") do
				running[id] = nil
			end
			for id, status in string.gmatch(t, "### (%S+) %[%w+%] — (%w+)") do
				if status ~= "running" then
					running[id] = nil
				end
			end
		end
	end
	local out: { Job } = {}
	for _, j in running do
		table.insert(out, j)
	end
	table.sort(out, function(x, y)
		return (x.at or 0) < (y.at or 0)
	end)
	return out
end

-- Maps panes to session files (`tern inspect`), then reads each file's job
-- lines with grep; calls `done` with a fresh cx once every file is read.
-- False when no scan started (one runs already, or no `tern`).
local function scan(done: (cx: WindowCx) -> ()): boolean
	local bin = find(TERN)
	if scanning or not bin then
		return false
	end
	scanning = true
	local ok = pcall(function()
		tern.process.run({ bin, "inspect", "--json" }, { timeout_ms = 10000 }, function(r: ProcessResult, cx: WindowCx?)
			local okj, data = pcall(tern.json.decode, r.stdout)
			local files: { [string]: string } = {}
			if r.status == 0 and okj and type(data) == "table" and type(data.panes) == "table" then
				for _, p in data.panes do
					if type(p.pane) == "number" and type(p.omp_session_file) == "string" then
						files[key_of(p.pane)] = p.omp_session_file
					end
				end
				session_files = files
			end
			local pending = 0
			for key, file in session_files do
				pending += 1
				local started = pcall(function()
					tern.process.run({ "/usr/bin/grep", "-E", JOB_LINES, file }, { timeout_ms = 10000 }, function(g, cx2)
						-- grep exits 1 when no line matches: no jobs.
						if g.status == 0 or g.status == 1 then
							bg[key] = running_jobs(g.stdout)
						end
						pending -= 1
						if pending == 0 then
							scanning = false
							if cx2 then
								done(cx2)
							end
						end
					end)
				end)
				if not started then
					pending -= 1
				end
			end
			if pending == 0 then
				scanning = false
				if cx then
					done(cx)
				end
			end
		end)
	end)
	if not ok then
		scanning = false
	end
	return ok
end

-- Collecting ---------------------------------------------------------------

local collect: (cx: WindowCx) -> ()
local pump: (cx: WindowCx) -> ()

local function store(key: string, s: Summary)
	local all = load_summaries()
	all[key] = s
	tern.kv.set("summaries", all)
end

local function summarize(cx: WindowCx, job: { key: string, pane: number, fp: string })
	local omp = find(OMP)
	local agent: AgentBlock? = nil
	for _, a in cx.agents:list() do
		if a.pane == job.pane then
			agent = a
		end
	end
	if not omp or not agent then
		jobs[job.key] = nil
		if not omp then
			store(job.key, { fp = job.fp, at = os.time(), error = "omp not found" })
		end
		return
	end
	local a = agent :: AgentBlock
	local info = cx.session:pane(job.pane)
	local title = if info then info.title else str(a.command)
	local ok, messages = pcall(function()
		return cx.agents:transcript(job.pane, { last = 200 })
	end)
	local conversation: string
	if ok and #messages > 0 then
		conversation = digest(messages)
	elseif ok and string.find(str(a.command) .. " " .. (if info then str(info.program) else ""), "omp", 1, true) then
		-- An omp with no transcript has no messages yet: nothing to summarize.
		jobs[job.key] = nil
		forced[job.key] = nil
		store(job.key, {
			fp = job.fp,
			at = os.time(),
			status = "The session has no messages.",
			todo = tern.json.array(),
			can_close = true,
		})
		tern.timer(0, function(cx2: WindowCx?)
			if cx2 then
				collect(cx2)
			end
		end)
		return
	else
		-- Non-omp agents have no transcript: read the screen.
		local read = cx.session:read(job.pane, { as = "text", lines = 400, max_chars = DIGEST_CHARS })
		conversation = if type(read) == "string" then read else ""
	end
	local started = pcall(function()
		tern.process.run({
			omp,
			"-p",
			"--no-session",
			"--no-tools",
			"--no-skills",
			"--no-rules",
			"--no-context-files",
			"--no-extensions",
			"--no-title",
			"--thinking",
			"off",
			"--model",
			MODEL,
		}, {
			cwd = tern.plugin.data,
			env = { PATH = PATH, NO_COLOR = "1" },
			stdin = prompt_for(a, title, conversation, if a.state == "exited" then {} else bg[job.key] or {}),
			timeout_ms = SUMMARY_TIMEOUT_MS,
		}, function(r: ProcessResult, cx2: WindowCx?)
			jobs[job.key] = nil
			forced[job.key] = nil
			local d = if r.status == 0 then parse(r.stdout) else nil
			if d then
				store(job.key, to_summary(job.fp, d))
			else
				local why = if r.timed_out
					then "timed out"
					elseif r.status ~= 0 then first_line(r.stderr)
					else "no JSON in the reply"
				-- Keep the last good card; note the failure on it.
				local old = load_summaries()[job.key]
				local s: Summary = if type(old) == "table" then old else { at = os.time() }
				s.fp = job.fp
				s.error = clip(why, 300)
				store(job.key, s)
			end
			if cx2 then
				pump(cx2)
				collect(cx2)
			end
		end)
	end)
	if not started then
		jobs[job.key] = nil
		store(job.key, { fp = job.fp, at = os.time(), error = "could not start omp" })
	end
end

function pump(cx: WindowCx)
	local running = 0
	for _ in jobs do
		running += 1
	end
	while running < CONCURRENCY and #queue > 0 do
		local job = table.remove(queue, 1) :: { key: string, pane: number, fp: string }
		if not jobs[job.key] then
			jobs[job.key] = true
			running += 1
			summarize(cx, job)
		end
	end
end

local function queued(key: string): boolean
	for _, j in queue do
		if j.key == key then
			return true
		end
	end
	return false
end

-- Order: needs you, then working, then the rest; newest pane first within each.
local function rank(row: { [string]: any }): number
	if row.needs_you then
		return 0
	elseif row.state == "working" then
		return 1
	elseif row.state == "exited" then
		return 3
	end
	return 2
end

function collect(cx: WindowCx)
	if not lead(cx) then
		return
	end
	local ok, agents = pcall(function()
		return cx.agents:list()
	end)
	if not ok then
		tern.log.warn("session-manager: cx.agents:list failed:", agents)
		return
	end
	local summaries = load_summaries()
	local session_of: { [number]: string } = {}
	for _, s in cx.session:sessions() do
		for _, t in s.tabs do
			session_of[t] = s.name
		end
	end
	local rows: { any } = {}
	local live: { [string]: boolean } = {}
	for _, a in agents do
		local key = key_of(a.pane)
		live[key] = true
		local info = cx.session:pane(a.pane)
		local tab = cx.session:tab_of(a.pane)
		local last = if type(a.last_message) == "string" then a.last_message else ""
		local running = if a.state == "exited" then {} else bg[key] or {}
		local ids: { string } = {}
		for _, j in running do
			table.insert(ids, j.id)
		end
		-- A job starting or ending changes the card as a turn does.
		local fp = tern.sha256(a.state .. "\0" .. last .. "\0" .. table.concat(ids, ","))
		local s = summaries[key]
		local stale = type(s) ~= "table" or s.fp ~= fp
		if
			(forced[key] or (stale and a.state ~= "working"))
			and not jobs[key]
			and not queued(key)
		then
			table.insert(queue, { key = key, pane = a.pane, fp = fp })
		end
		table.insert(rows, {
			pane = key,
			title = if info and info.title ~= "" then info.title else str(a.command),
			cwd = a.cwd,
			state = a.state,
			model = if type(a.model) == "string" then a.model else nil,
			session = if tab then session_of[tab] else nil,
			parked = info ~= nil and info.parked == true,
			summarizing = jobs[key] == true or queued(key),
			stale = stale,
			summary = if type(s) == "table" then s else nil,
			jobs = tern.json.array(running),
			-- A working agent does not wait on you now; what it will need later is a todo.
			needs_you = a.state == "waiting_input"
				or (a.state ~= "working" and type(s) == "table" and s.needs_you == true and not stale),
		})
	end
	table.sort(rows, function(x, y)
		local rx, ry = rank(x), rank(y)
		if rx ~= ry then
			return rx < ry
		end
		return x.pane > y.pane
	end)
	-- Forget closed panes.
	for key in bg do
		if not live[key] then
			bg[key] = nil
		end
	end
	local pruned = false
	for key in summaries do
		if not live[key] then
			summaries[key] = nil
			pruned = true
		end
	end
	if pruned then
		tern.kv.set("summaries", summaries)
	end
	pump(cx)
	-- `summarizing` may have changed in pump.
	for _, row in rows do
		row.summarizing = jobs[row.pane] == true or queued(row.pane)
	end
	local board = { rows = tern.json.array(rows), window = cx:window_key() }
	local old = tern.kv.get("board")
	local encoded = tern.json.encode(board)
	if type(old) ~= "table" or tern.json.encode({ rows = old.rows, window = old.window }) ~= encoded then
		board.at = os.time()
		tern.kv.set("board", board)
	end
end

local function soon(cx: WindowCx)
	if settle then
		settle:cancel()
	end
	settle = tern.timer(SETTLE_MS, function(cx2: WindowCx?)
		settle = nil
		-- Jobs first: a summary made before the scan would be stale at once.
		if cx2 and not scan(collect) then
			collect(cx2)
		end
	end)
	-- Show the new state at once; summaries wait for it to settle.
	collect(cx)
end

-- Events -------------------------------------------------------------------

for _, name in { "agent_state", "agent_finished", "pane_closed", "title" } do
	tern.on(name, function(_ev: any, cx: WindowCx)
		soon(cx)
	end)
end

tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	if ev.pane ~= board_pane(cx) then
		last_focus = ev.pane
	end
end)

local function tick(cx: WindowCx?)
	if cx then
		collect(cx)
		if lead(cx) then
			scan(collect)
		end
	end
	tern.timer(TICK_MS, tick)
end
tern.timer(0, tick)

-- The board: open it, or toggle between it and the pane you came from.
local function toggle(cx: WindowCx)
	local board = board_pane(cx)
	local focused = cx.session:focused()
	if board and focused == board then
		if last_focus and reveal(cx, last_focus) then
			return
		end
	elseif board then
		reveal(cx, board)
		return
	end
	if not board then
		lead(cx, true)
		collect(cx)
		if not cx:new_block(KIND, {}, "tab") then
			cx:toast("error", "Session Manager is not loaded on this host")
		end
	end
end

tern.command({ id = "toggle", title = "Sessions: show the session board", icon = "list", run = toggle })
-- Hyper (Raycast's Caps Lock long-press) + K, beside tab-nav's Hyper + T.
tern.bind("ctrl+alt+shift+cmd+k", "plugin.session-manager.toggle")

-- Links from the block's buttons -------------------------------------------

-- Ends the session and closes its tab: the agent block and every other pane in
-- that tab, after a confirmation that says what else closes. The board and
-- canvas sidebars (they follow the shown tab) stay.
local function close_session(cx: WindowCx, pane: number)
	local info = cx.session:pane(pane)
	if not info then
		cx:toast("error", "That session's pane is gone")
		return
	end
	local board = board_pane(cx)
	local tab = cx.session:tab_of(pane)
	local others: { PaneInfo } = {}
	if tab then
		for _, p in cx.session:panes() do
			if p.tab == tab and p.pane ~= pane and p.pane ~= board and p.program ~= "tern.canvas" and p.block ~= "tern.canvas" then
				table.insert(others, p)
			end
		end
	end
	local busy = 0
	for _, p in others do
		if p.busy or p.running then
			busy += 1
		end
	end
	local detail = if #others == 0
		then "Its tab closes with it."
		else string.format(
			"%d other pane%s in its tab close too%s.",
			#others,
			if #others == 1 then "" else "s",
			if busy > 0 then string.format(" (%d running a command)", busy) else ""
		)
	cx:pick({
		items = {
			{ label = "Close the session and its tab", detail = detail, close = true },
			{ label = "Cancel" },
		},
		placeholder = "Close " .. info.title .. "?",
		action = "choose",
	}):next(function(item: PickItem?, _err: string?, cx2: WindowCx?)
		if not cx2 or not item or not item.close then
			return
		end
		local stopped = pcall(function()
			cx2.agents:stop(pane)
		end)
		if not stopped and cx2.session:pane(pane) then
			cx2.layout:close(pane)
		end
		for _, p in others do
			if cx2.session:pane(p.pane) then
				cx2.layout:close(p.pane)
			end
		end
		local all = load_summaries()
		all[key_of(pane)] = nil
		tern.kv.set("summaries", all)
		collect(cx2)
		cx2:toast("success", "Closed " .. info.title)
	end)
end

local function reply(cx: WindowCx, pane: number)
	local info = cx.session:pane(pane)
	cx:prompt({
		placeholder = "Reply to " .. (if info then info.title else "the session"),
		action = "send",
	}):next(function(text: string?, _err: string?, cx2: WindowCx?)
		if not cx2 or not text or not string.match(text, "%S") then
			return
		end
		local ok, err = pcall(function()
			cx2.agents:ask(pane, text)
		end)
		if ok then
			cx2:toast("success", "Sent to the session")
		else
			cx2:toast("error", "Could not send the reply", tostring(err))
		end
	end)
end

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if string.sub(link.url, 1, #LINK) ~= LINK then
		return nil
	end
	local verb = string.match(string.sub(link.url, #LINK + 1), "^([%w_]+)")
	local q = query(link.url)
	local pane = tonumber(q.pane)
	if verb == "open" and pane then
		if not reveal(cx, pane) then
			cx:toast("error", "That session's pane is gone")
		end
	elseif verb == "close" and pane then
		close_session(cx, pane)
	elseif verb == "reply" and pane then
		reply(cx, pane)
	elseif verb == "refresh" then
		lead(cx, true)
		if pane then
			forced[key_of(pane)] = true
		else
			for _, a in cx.agents:list() do
				forced[key_of(a.pane)] = true
			end
		end
		collect(cx)
	end
	return { handled = true }
end)
