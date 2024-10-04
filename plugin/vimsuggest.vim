if !has('vim9script') || v:version < 901
    " Needs Vim version 9.1 and above
    finish
endif

vim9script

g:loaded_vimsuggest = true

import autoload '../autoload/vimsuggest/options.vim' as opt
import autoload '../autoload/vimsuggest/search.vim'
import autoload '../autoload/vimsuggest/cmd.vim'
import autoload '../autoload/vimsuggest/addons/find.vim'

def! g:VimSuggestSetOptions(opts: dict<any>)
    var Update = (key) => {
        if opts->has_key(key)
            opt.options[key]->extend(opts[key])
        endif
    }
    Update('search')
    Update('cmd')
    if opt.options.search.fuzzy
        opt.options.search.async = false
    endif
    Reset()
enddef

def! g:VimSuggestGetOptions(): dict<any>
    return opt.options->deepcopy()
enddef

def VimSuggestgestEnable(flag: bool)
    opt.options.search.enable = flag
    opt.options.cmd.enable = flag
    Reset()
enddef
command! VimSuggestEnable  VimSuggestEnable(true)
command! VimSuggestDisable VimSuggestEnable(false)

if empty(prop_type_get('VimSuggestMatch'))
    :highlight default link VimSuggestMatch PmenuMatch
    prop_type_add('VimSuggestMatch', {highlight: "VimSuggestMatch", override: false})
endif
:highlight default link VimSuggestMatchSel PmenuMatchSel

def Reset()
    search.Teardown()
    search.Setup()
    cmd.Teardown()
    cmd.Setup()
enddef

autocmd VimEnter * Reset()

# vim: tabstop=8 shiftwidth=4 softtabstop=4 expandtab
