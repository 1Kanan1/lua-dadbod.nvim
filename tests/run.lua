local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fn.fnamemodify(source, ":p:h:h")

package.path = table.concat({
	root .. "/lua/?.lua",
	root .. "/lua/?/init.lua",
	root .. "/?.lua",
	package.path,
}, ";")

vim.opt.runtimepath:append(root)
vim.cmd("runtime plugin/lua-dadbod.lua")

vim.notify = function(message, level)
	if level == vim.log.levels.ERROR then
		io.write("notify: " .. tostring(message) .. "\n")
	end
end

vim.o.hidden = true

local harness = require("tests.harness")

require("tests.url_spec")
require("tests.adapter_spec")
require("tests.job_spec")
require("tests.query_spec")
require("tests.result_table_spec")
require("tests.sqlite_spec")
require("tests.history_spec")
require("tests.ui_spec")
require("tests.config_spec")

harness.run()
