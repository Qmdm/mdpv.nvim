if vim.g.loaded_mdpv then
  return
end
vim.g.loaded_mdpv = true

if vim.fn.has('nvim-0.12') == 0 then
  vim.notify_once('mdpv.nvim requires Neovim 0.12+', vim.log.levels.ERROR)
  return
end

-- User commands must start with an uppercase letter, so :preview itself is
-- not possible; :Preview is the closest Neovim allows.
vim.api.nvim_create_user_command('Preview', function(cmd)
  require('mdpv')._command(cmd)
end, {
  nargs = '?',
  bang = true,
  complete = function(arglead)
    return require('mdpv')._complete(arglead)
  end,
  desc = 'GitHub-style markdown preview in the browser (:Preview [open|close|toggle|stop|list])',
})

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('mdpv.shutdown', { clear = true }),
  callback = function()
    -- Only tear down if the plugin was actually used this session.
    if package.loaded['mdpv.server'] then
      require('mdpv.server').stop()
    end
  end,
})
