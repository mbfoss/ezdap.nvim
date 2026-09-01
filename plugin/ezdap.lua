-- Bring ezdap up: the `:Ezdap` command and the project-state autocmds, and
-- nothing more. `setup()` is optional and stays useful afterwards — it is read
-- for configuration, not for initialisation.

if vim.g.loaded_ezdap then return end
vim.g.loaded_ezdap = true

require("ezdap.bootstrap").init()
