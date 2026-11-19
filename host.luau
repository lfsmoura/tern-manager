--!strict
-- The host half: the `board` block. It draws the board the window half
-- publishes under kv `board` (every agent block with its status card) and
-- polls kv for changes. Buttons open `tern-sessions://` links, which the
-- window half serves: a host block cannot focus panes or talk to agents.

local ui = tern.ui

local POLL_MS = 1000
local LINK = "tern-sessions://"

type State = {
	cx: BlockCx,
	board: any,
	-- The encoded board last drawn, to render only on change.
	shown: string?,
	minute: number?,
	poll: TimerHandle?,
}

local running: { [number]: State } = {}

local STATE_LABEL: { [string]: string } = {
	working = "working",
	waiting_input = "waiting for you",
	idle = "idle",
	exited = "exited",
}
local STATE_TONE: { [string]: string } = {
	working = "info",
	waiting_input = "warning",
	idle = "muted",
	exited = "muted",
}

local function str(v: any): string
	return if type(v) == "string" then v else ""
end

local function ago(at: any): string
	local t = tonumber(at)
	if not t then
		return ""
	end
	local s = os.time() - t
	if s < 60 then
		return "just now"
	elseif s < 3600 then
		return string.format("%dm ago", s // 60)
	elseif s < 86400 then
		return string.format("%dh ago", s // 3600)
	end
	return string.format("%dd ago", s // 86400)
end

local function short_path(p: string): string
	local home = tern.getenv("HOME")
	if home and string.sub(p, 1, #home) == home then
		return "~" .. string.sub(p, #home + 1)
	end
	return p
end

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	if state.poll then
		state.poll:cancel()
		state.poll = nil
	end
end

-- Blocks have no close hook: a restarted pane reuses its id, a closed one leaves the list.
local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	retire(state)
	return false
end

local function load(state: State): boolean
	local board = tern.kv.get("board")
	local encoded = tern.json.encode(board or tern.json.null)
	if encoded == state.shown then
		return false
	end
	state.shown = encoded
	state.board = board
	return true
end

local function poll(state: State)
	state.poll = tern.timer(POLL_MS, function(_)
		state.poll = nil
		if not alive(state) then
			return
		end
		-- Job run times count in minutes: draw again as each one passes.
		local minute = os.time() // 60
		if load(state) or minute ~= state.minute then
			state.minute = minute
			state.cx:render()
		end
		poll(state)
	end)
end

-- Rendering ----------------------------------------------------------------

local function todo_node(todo: { string }): Node
	local lines: { string } = {}
	for _, t in todo do
		table.insert(lines, "- [ ] " .. t)
	end
	return ui.md(table.concat(lines, "\n"))
end

local JOB_KIND: { [string]: string } = { bash = "shell job", eval = "eval job", task = "subagent" }

-- How long a job has run: `12m`, `2h 05m`.
local function elapsed(at: any): string
	local t = tonumber(at)
	if not t then
		return ""
	end
	local m = (os.time() - t) // 60
	if m < 1 then
		return "under 1m"
	elseif m < 60 then
		return string.format("%dm", m)
	end
	return string.format("%dh %02dm", m // 60, m % 60)
end

-- One running background job: what it is, and (from the summary) why the session runs it.
local function job_card(job: any, note: any, session: string): Node
	local body: { Node } = {}
	if note and str(note.purpose) ~= "" then
		table.insert(body, ui.text({ ui.span(note.purpose) }))
		if str(note.next) ~= "" then
			table.insert(body, ui.kv({ { "Then", note.next } }))
		end
	else
		table.insert(body, ui.text({ ui.span("Its purpose comes with the next summary.", "muted") }))
	end
	if str(job.detail) ~= "" then
		table.insert(body, ui.text({ ui.span(job.detail, if job.type == "task" then "muted" else "muted code") }))
	end
	local meta: { Span | string } = { ui.span(JOB_KIND[str(job.type)] or str(job.type), "info") }
	local run = elapsed(job.at)
	if run ~= "" then
		table.insert(meta, ui.span(" · running " .. run, "muted"))
	end
	return ui.card({ ui.span(str(job.id), "strong code"), ui.span("  " .. str(job.label)) }, body, {
		meta = meta,
		key = "job:" .. session .. ":" .. str(job.id),
		tone = "info",
	})
end

local function card(row: any): Node
	local id = str(row.pane)
	local s = if type(row.summary) == "table" then row.summary else nil
	local body: { Node } = {}
	if s and str(s.purpose) ~= "" then
		table.insert(body, ui.text({ ui.span(s.purpose, "strong") }))
	end
	if s and str(s.status) ~= "" then
		table.insert(body, ui.kv({ { "Status", s.status } }))
	end
	if row.needs_you then
		local why = if s and str(s.why) ~= "" and not row.stale
			then s.why
			else "The agent asks a question. Open the tab to answer it."
		table.insert(body, ui.kv({ { ui.span("Needs you", "warning strong"), ui.span(why, "warning") } }))
	end
	local running: { any } = if type(row.jobs) == "table" then row.jobs else {}
	if #running > 0 then
		local notes: { [string]: any } = {}
		for _, n in (if s and type(s.jobs) == "table" then s.jobs else {}) :: { any } do
			notes[str(n.id)] = n
		end
		local cards: { Node } = {}
		for _, j in running do
			table.insert(cards, job_card(j, notes[str(j.id)], id))
		end
		table.insert(body, ui.section(string.format("Background jobs (%d)", #running), cards))
	end
	if s and type(s.todo) == "table" then
		if #s.todo > 0 then
			table.insert(body, ui.section(string.format("Before you close (%d)", #s.todo), { todo_node(s.todo) }))
		elseif s.can_close and #running == 0 then
			table.insert(body, ui.text({ ui.span("✓ Nothing left: you can close this session.", "success") }))
		end
	end
	if row.summarizing then
		table.insert(body, ui.text({ ui.span(if s then "Updating the summary…" else "Summarizing…", "muted") }))
	elseif not s and row.state == "working" then
		table.insert(body, ui.text({ ui.span("Summary comes when this turn ends.", "muted") }))
	elseif s and row.stale then
		table.insert(body, ui.text({ ui.span("Summary is from before the latest turn.", "muted") }))
	end
	if s and str(s.error) ~= "" then
		table.insert(body, ui.text({ ui.span("Summary failed: " .. s.error, "error") }))
	end
	table.insert(
		body,
		ui.row({
			ui.button("Open tab", {
				variant = "primary",
				size = "sm",
				key = "open:" .. id,
				actions = { click = "open=" .. id },
			}),
			ui.button("Reply", { size = "sm", key = "reply:" .. id, actions = { click = "reply=" .. id } }),
			ui.button("Close", {
				variant = "danger",
				size = "sm",
				key = "close:" .. id,
				actions = { click = "close=" .. id },
			}),
			ui.button("Summarize again", {
				variant = "quiet",
				size = "sm",
				key = "refresh:" .. id,
				busy = row.summarizing == true,
				actions = { click = "refresh=" .. id },
			}),
		})
	)
	local meta: { Span | string } = {
		ui.span(STATE_LABEL[row.state] or str(row.state), STATE_TONE[row.state]),
	}
	local where = str(row.session)
	if where ~= "" then
		table.insert(meta, ui.span(" · " .. where, "muted"))
	end
	if row.parked then
		table.insert(meta, ui.span(" · parked", "muted"))
	end
	table.insert(meta, ui.span(" · " .. short_path(str(row.cwd)), "muted path"))
	if s and s.at then
		table.insert(meta, ui.span(" · summary " .. ago(s.at), "muted"))
	end
	local props: { [string]: any } = { meta = meta, key = "card:" .. id }
	if row.needs_you then
		props.tone = "warning"
	elseif row.state == "working" then
		props.tone = "info"
	end
	return ui.card({ ui.span(str(row.title), "strong") }, body, props)
end

local function main_view(state: State): Node
	local board = state.board
	local rows: { any } = if type(board) == "table" and type(board.rows) == "table" then board.rows else {}
	local need, working, closable, background = 0, 0, 0, 0
	for _, r in rows do
		local running = if type(r.jobs) == "table" then #r.jobs else 0
		background += running
		if r.needs_you then
			need += 1
		end
		if r.state == "working" then
			working += 1
		end
		if type(r.summary) == "table" and r.summary.can_close and not r.stale and running == 0 then
			closable += 1
		end
	end
	local children: { Node } = {
		ui.stats({
			{ label = "Sessions", value = tostring(#rows) },
			{ label = "Need you", value = tostring(need), tone = if need > 0 then "warning" else nil },
			{ label = "Working", value = tostring(working), tone = if working > 0 then "info" else nil },
			{ label = "Background jobs", value = tostring(background), tone = if background > 0 then "info" else nil },
			{ label = "Can close", value = tostring(closable), tone = if closable > 0 then "success" else nil },
		}),
	}
	if type(board) ~= "table" then
		table.insert(children, ui.text({ ui.span("Waiting for a Tern window to list the sessions…", "muted") }))
	elseif #rows == 0 then
		table.insert(children, ui.text({ ui.span("No agent sessions are open.", "muted") }))
	end
	for _, r in rows do
		table.insert(children, card(r))
	end
	return ui.col(children)
end

local function dock_view(): Node
	return ui.col({
		ui.row({
			ui.button("Summarize all again", { size = "sm", variant = "quiet", key = "refresh-all", actions = { click = "refresh" } }),
			ui.text({
				ui.span("r", "key"),
				ui.span(" summarize all   ", "muted"),
				ui.span("⌃⌥⇧⌘K", "key"),
				ui.span(" back and forth", "muted"),
			}),
		}),
	})
end

local function act(state: State, name: string, value: string?)
	if name == "open" or name == "reply" or name == "close" then
		if value then
			state.cx:open(LINK .. name .. "?pane=" .. value)
		end
	elseif name == "refresh" then
		state.cx:open(LINK .. "refresh" .. (if value then "?pane=" .. value else ""))
	end
end

tern.block.define("board", {
	init = function(cx: BlockCx, _args: { string }, _saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local state: State = { cx = cx, board = nil, shown = nil, minute = nil, poll = nil }
		running[cx.pane] = state
		load(state)
		poll(state)
		return state
	end,

	title = function(_state: State): string?
		return "Sessions"
	end,

	font = "sans",

	view = function(state: State, _cx: BlockCx): BlockView
		return { main = main_view(state), dock = dock_view() }
	end,

	key = function(state: State, key: Key, _cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		if (key.text or key.name) == "r" then
			act(state, "refresh", nil)
		end
		return false
	end,

	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		if ev.ev == "action" and type(ev.act) == "string" then
			act(state, ev.act, if type(ev.value) == "string" then ev.value else nil)
		end
	end,
})
