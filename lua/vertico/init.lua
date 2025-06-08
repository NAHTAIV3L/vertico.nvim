local M = {}

local async = require("plenary.async")
local channel = require("plenary.async.control").channel
local await_schedule = async.util.scheduler

local defaults = {
    height = 10
}

local ns_vertico_results = vim.api.nvim_create_namespace("vertico_results")

-- Get the directory from a string
---@param path string: the string to get the directory from
---@return string: the string ending at the directory
local function get_directory_from_string(path)
    local res = { path:find("^.*()/") }
    if res[1] == nil then
        return ""
    end
    return path:sub(res[1], res[2])
end

-- get the current search term
---@param str string: the current full prompt string
---@return string: the search term
local function get_search_term(str)
    local res = {str:find("/[^/]*$")}
    if res[1] == nil then
        return ""
    end
    return str:sub(res[1] + 1, res[2])
end

-- Get the directory the current buffer is in
---@return string
local function get_current_buffer_directory()
    return get_directory_from_string(vim.api.nvim_buf_get_name(0))
end

-- List all the files in a directory
---@param current_dir string: current working directory
---@return string[]
local function list_directory(current_dir)
    if current_dir == nil then
        current_dir = get_current_buffer_directory()
    end

    local cmd = "ls -AFL " .. current_dir
    local handle = io.popen(cmd)
    local result
    if handle ~= nil then
        result = handle:read("*a")
        handle:close()
    end
    return vim.fn.split(result, "\n")
end

-- Close buffers
function M.close()
    if vim.api.nvim_buf_is_valid(M._input_buffer) then
        vim.api.nvim_buf_delete(M._input_buffer, { force = true })
    end
    if vim.api.nvim_buf_is_valid(M._result_buffer) then
        vim.api.nvim_buf_delete(M._result_buffer, { force = true })
    end
    vim.o.cmdheight = M._restore.cmdheight
end

function M.setup(opts)
    defaults = opts or defaults
end

local function update_results()
    local prompt = vim.api.nvim_buf_get_lines(M._input_buffer, 0, 1, false)[1]
    local status, results = pcall(list_directory, M._current_dir)
    if ~status then return end
    local files = vim.iter(results)
        :filter(function (file)
            return file:find(get_search_term(prompt), 1, true)
        end)
        :map(function (file)
            if file:find("@", #file - 1, true) or file:find("*", #file - 1, true) then
                return file:sub(0, #file - 1)
            end
            return file
        end):totable()
    local num_lines = vim.api.nvim_buf_line_count(M._result_buffer)
    vim.api.nvim_buf_set_lines(M._result_buffer, 0, num_lines, false, { "" })
    vim.api.nvim_buf_set_lines(M._result_buffer, 0, #files, false, files)

    num_lines = vim.api.nvim_buf_line_count(M._result_buffer)

    if M._highlight_line < 0 then
        M._highlight_line = 0
    elseif M._highlight_line >= num_lines then
        M._highlight_line = num_lines - 1
    end

    vim.hl.range(M._result_buffer, ns_vertico_results, "VisualNOS", { M._highlight_line, 0 }, { M._highlight_line, vim.o.columns }, {})
    vim.api.nvim_win_set_cursor(M._result_win, { M._highlight_line + 1, 0 })
end

function M.prev()
    M._highlight_line = M._highlight_line - 1
    update_results()
end

function M.next()
    M._highlight_line = M._highlight_line + 1
    update_results()
end

function M.find_file()
    M._current_dir = get_current_buffer_directory()
    if M._current_dir == "" then
        M._current_dir = vim.cmd.pwd()
    end
    M._highlight_line = 0
    M._restore = {
        cmdheight = vim.o.cmdheight
    }
    M._result_buffer = vim.api.nvim_create_buf(false, false)
    vim.bo[M._result_buffer].buftype =  "nowrite"
    M._input_buffer = vim.api.nvim_create_buf(false, false)
    vim.bo[M._input_buffer].buftype = "prompt"
    vim.fn.prompt_setcallback( M._input_buffer, function(path)
        M.close()
        vim.cmd(":e " .. path)
    end)

    ---@type vim.api.keyset.win_config
    local input_win_config = {
        relative = "editor",
        border = "none",
        style = "minimal",
        focusable = true,
        row = vim.o.lines - defaults.height,
        col = 0,
        width = vim.o.columns,
        height = 1,
        zindex = 400,
    }
    ---@type vim.api.keyset.win_config
    local result_win_config = {
        relative = "editor",
        border = "none",
        style = "minimal",
        focusable = false,
        row = vim.o.lines - defaults.height + 1,
        col = 0,
        width = vim.o.columns,
        height = defaults.height - 1,
        zindex = 400,
    }
    M._result_win = vim.api.nvim_open_win(M._result_buffer, false, result_win_config)
    M._input_win= vim.api.nvim_open_win(M._input_buffer, true, input_win_config)
    vim.o.cmdheight = defaults.height
    vim.fn.prompt_setprompt(M._input_buffer, "")
    vim.api.nvim_buf_set_lines(M._input_buffer, 0, 1, true, { M._current_dir })
    -- vim.fn.prompt_setprompt(M._input_buffer, M._current_dir)
    update_results()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), 'm', true)

    vim.api.nvim_create_autocmd("WinClosed", {
        callback = function()
            M.close()
        end,
        buffer = M._input_buffer})

    vim.api.nvim_create_autocmd("VimResized", {
        callback = function()
            result_win_config.row = vim.o.lines - defaults.height + 1
            result_win_config.width = vim.o.columns
            input_win_config.row = vim.o.lines - defaults.height
            vim.api.nvim_win_set_config(M._result_win, result_win_config)
            vim.api.nvim_win_set_config(M._input_win, input_win_config)
        end
    })

    local tx, rx = channel.mpsc()

    vim.api.nvim_buf_attach(M._input_buffer, true, {
        on_lines = function(...)
            tx.send(...)
        end})

    vim.keymap.set("n", "<Esc>", M.close, { buffer = M._input_buffer })

    vim.keymap.set("i", "<CR>", function()
        local prompt = vim.api.nvim_buf_get_lines(M._input_buffer, 0, 1, false)[1]
        M.close()
        vim.cmd("e " .. prompt)
    end, { buffer = M._input_buffer })

    vim.keymap.set("n", ":", function()
        M.close()
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes(":", true, false, true),
            'm',
            true)
    end, { buffer = M._input_buffer })

    vim.keymap.set("n", "q", M.close, { buffer = M._input_buffer })

    vim.keymap.set({ "i", "n" }, "<C-n>", M.next, { buffer = M._input_buffer })

    vim.keymap.set({ "i", "n" }, "<C-p>", M.prev, { buffer = M._input_buffer })

    vim.keymap.set({ "i" }, "<Tab>", function()
        local num_lines = vim.api.nvim_buf_line_count(M._result_buffer)
        local files = vim.api.nvim_buf_get_lines(M._result_buffer, 0, num_lines, false)

        local prompt = vim.api.nvim_buf_get_lines(M._input_buffer, 0, 1, false)[1]
        prompt = get_directory_from_string(prompt) .. files[M._highlight_line + 1]

        vim.api.nvim_buf_set_lines(M._input_buffer, 0, 1, false, { prompt })
        vim.api.nvim_win_set_cursor(M._input_win, { 1, #prompt })
        M._highlight_line = 0
    end, { buffer = M._input_buffer })

    vim.keymap.set("i", "<C-BS>", function()
        local prompt = vim.api.nvim_buf_get_lines(M._input_buffer, 0, 1, false)[1]
        if prompt:sub(#prompt) == "/" then
            prompt = get_directory_from_string(prompt:sub(0, #prompt - 1))
        else
            prompt = get_directory_from_string(prompt)
        end
        vim.api.nvim_buf_set_lines(M._input_buffer, 0, 1, false, { prompt })
    end, { buffer = M._input_buffer })


    local main = async.void(function()
        await_schedule()
        while true do
            rx.last()
            await_schedule()
            local line = vim.api.nvim_buf_get_lines(M._input_buffer, 0, 1, false)[1]
            if get_directory_from_string(line) ~= M._current_dir then
                M._current_dir = get_directory_from_string(line)
                M._highlight_line = 0
            end
            update_results()
        end
    end)
    main()
end

M.find_file()

return M
