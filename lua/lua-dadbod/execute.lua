local db = require("lua-dadbod.db")
local result = require("lua-dadbod.result")
local url = require("lua-dadbod.url")
local util = require("lua-dadbod.util")

local M = {}

local function emit(event, data)
	pcall(vim.api.nvim_exec_autocmds, "User", {
		pattern = event,
		data = data,
	})
end

local function source_buffer(opts)
	local bufnr = opts.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		bufnr = vim.api.nvim_get_current_buf()
	end
	return bufnr
end

local function result_for(source, opts)
	local existing = vim.b[source].lua_dadbod_result_buf
	if existing and vim.api.nvim_buf_is_valid(existing) and not opts.bang then
		local meta = vim.b[existing].lua_dadbod_result
		if meta and meta.status == "running" then
			return nil, "a query is already running for this buffer; use :DB! to start another"
		end
		result.reset(existing, opts)
		return existing
	end

	local bufnr = result.open(opts)
	vim.b[source].lua_dadbod_result_buf = bufnr
	return bufnr
end

function M.run(sql, opts, callback)
	opts = opts or {}
	local source = source_buffer(opts)

	local connection
	if opts.conn and opts.conn ~= "" then
		connection = opts.conn
	elseif opts.conn_url and opts.conn_url ~= "" then
		connection = opts.conn_url
	else
		local resolved, err = db.resolve_buffer(source)
		if not resolved then
			return nil, err
		end
		connection = resolved
	end

	local parsed, adapter = db.parse(connection)
	if not parsed or not adapter then
		return nil, adapter or "invalid connection URL"
	end

	local canonical = url.format(parsed)
	local ui = require("lua-dadbod.ui")
	local configured = opts.conn_key and ui.get(opts.conn_key) or nil
	if not configured then
		configured = ui.find_by_url(canonical)
	end

	local display = opts.name or (configured and configured.name) or url.safe_format(parsed)
	local history_name = opts.name or (configured and configured.name) or url.display_name(parsed)
	local result_buf, result_err = result_for(source, {
		source_buf = source,
		conn = canonical,
		conn_key = opts.conn_key,
		name = display,
		sql = sql,
		format = adapter.result_format,
		bang = opts.bang,
	})
	if not result_buf then
		return nil, result_err
	end

	local generation = vim.b[result_buf].lua_dadbod_result.generation

	emit("LuaDadbodQueryPre", {
		conn = display,
		sql = sql,
	})

	local handle, run_err = db.run(canonical, sql, {
		timeout = opts.timeout,
	}, function(query_result)
		require("lua-dadbod.history").add({
			conn = canonical,
			dbms = adapter.name,
			name = history_name,
			key = opts.conn_key,
			sql = sql,
			code = query_result.code,
			signal = query_result.signal,
			elapsed = query_result.elapsed,
			timed_out = query_result.timed_out,
		})

		local current = vim.api.nvim_buf_is_valid(result_buf) and vim.b[result_buf].lua_dadbod_result or nil
		local is_current = current ~= nil and current.generation == generation
		if is_current then
			result.update(result_buf, query_result)
		end
		emit("LuaDadbodQueryPost", {
			conn = display,
			sql = sql,
			code = query_result.code,
			elapsed = query_result.elapsed,
			timed_out = query_result.timed_out,
		})
		if is_current and callback then
			callback(query_result)
		end
	end)

	if not handle then
		result.update(result_buf, {
			code = 1,
			signal = 0,
			stdout = "",
			stderr = run_err or "failed to start query",
			elapsed = 0,
			timed_out = false,
		})
		emit("LuaDadbodQueryPost", {
			conn = display,
			sql = sql,
			code = 1,
			elapsed = 0,
			timed_out = false,
		})
		return nil, run_err
	end

	result.set_job(result_buf, handle)
	return result_buf, nil, handle
end

function M.run_buffer(opts)
	opts = opts or {}
	local bufnr = source_buffer(opts)

	local lines
	if opts.line1 and opts.line2 then
		lines = vim.api.nvim_buf_get_lines(bufnr, opts.line1 - 1, opts.line2, false)
	else
		lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	end

	local statement = table.concat(lines, "\n")
	if util.trim(statement) == "" then
		return nil, "empty query"
	end

	local meta = vim.b[bufnr].lua_dadbod or {}
	local bind = meta.bind or {}
	local query = require("lua-dadbod.query")

	query.resolve_binds(statement, bind, function(resolved, updated_bind)
		meta.bind = updated_bind
		vim.b[bufnr].lua_dadbod = meta
		M.run(resolved, {
			bufnr = bufnr,
			conn = opts.conn or meta.conn or meta.url,
			conn_key = opts.conn_key or meta.conn_key,
			name = opts.name or meta.conn_name,
			bang = opts.bang,
			timeout = opts.timeout,
		}, opts.callback)
	end)

	return bufnr
end

local function looks_like_url(token)
	if not token or token == "" then
		return false
	end
	if token:match("^%$[%w_]+$") or token:match("^%${[%w_]+}$") then
		return true
	end
	return token:match("^[%a][%w%+%-%.]*:") ~= nil
end

local function parse_args(args)
	args = util.trim(args or "")
	if args == "" then
		return nil, nil
	end

	local file = args:match("^<%s*(.+)$")
	if file then
		return nil, nil, util.trim(file)
	end

	local first, rest = args:match("^(%S+)%s*(.*)$")
	if first and looks_like_url(first) then
		return first, rest
	end

	return nil, args
end

function M.db_command(opts)
	local connection, statement, file = parse_args(opts.args)
	if file then
		file = vim.fn.expand(file)
		local lines, err = util.read_file(file)
		if not lines then
			return nil, err
		end
		statement = table.concat(lines, "\n")
	end

	if (opts.range or 0) > 0 then
		if statement and statement ~= "" then
			return nil, "range form accepts a connection URL only"
		end
		return M.run_buffer({
			bufnr = vim.api.nvim_get_current_buf(),
			line1 = opts.line1,
			line2 = opts.line2,
			conn = connection,
			bang = opts.bang,
		})
	end

	if statement and statement ~= "" then
		return M.run(statement, {
			bufnr = vim.api.nvim_get_current_buf(),
			conn = connection,
			bang = opts.bang,
		})
	end

	return M.console(connection, vim.api.nvim_get_current_buf())
end

function M.console(connection, bufnr)
	local parsed, adapter
	if connection and connection ~= "" then
		parsed, adapter = db.parse(connection)
	else
		local resolved, err = db.resolve_buffer(bufnr)
		if not resolved then
			return nil, err
		end
		parsed, adapter = db.parse(resolved)
	end

	if not parsed or not adapter then
		return nil, adapter or "invalid connection URL"
	end
	if not adapter.interactive then
		return nil, "interactive mode is not supported for " .. adapter.name
	end

	local ok, err = db.check_binary(url.format(parsed))
	if not ok then
		return nil, err
	end

	local argv, env = adapter.interactive(parsed)
	local previous = vim.api.nvim_get_current_win()
	vim.cmd("botright new")
	local buf = vim.api.nvim_get_current_buf()

	local started, job_id = pcall(vim.fn.jobstart, argv, { term = true, env = env })
	if not started or type(job_id) ~= "number" or job_id <= 0 then
		vim.api.nvim_set_current_win(previous)
		return nil, "failed to start interactive console"
	end

	vim.cmd.startinsert()
	return buf
end

M.parse_args = parse_args

return M
