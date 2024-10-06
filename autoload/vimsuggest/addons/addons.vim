vim9script

import autoload '../cmd.vim'
# import autoload './fuzzy.vim'
import './fuzzy.vim' # Debug: Avoid autoloading to prevent delaying compilation until the autocompletion phase.
import autoload './live.vim'

export def Enable()
    ## (Fuzzy) Find Files
    command! -nargs=* -complete=customlist,fuzzy.FindComplete VSFind fuzzy.DoFindAction('edit', <f-args>)
    ## (Live) Grep
    command! -nargs=+ -complete=customlist,DoLiveGrepComplete VSLiveGrep live.DoCommand(live.DefaultAction, <f-args>)

    # command! -nargs=+ -complete=customlist,DoLiveFindComplete VSLiveFind live.DoCommand(live.DefaultAction, <f-args>)
    # command! -nargs=* -complete=customlist,live.DoComplete VSLive live.DoCommand(live.DefaultAction, <f-args>)
    # command! -nargs=* -complete=customlist,live.DoCompleteSh VSLiveSh live.DoCommand(live.DefaultAction, <f-args>)

    command! -nargs=* -complete=customlist,BufferComplete VSBuffer DoBufferAction(<f-args>)

    command! -nargs=* -complete=customlist,MRUComplete VSMru DoMRUAction(<f-args>)

    command! -nargs=* -complete=customlist,KeymapComplete VSKeymap DoKeymapAction(<f-args>)

    command! -nargs=* -complete=customlist,MarkComplete VSMark DoMarkAction(<f-args>)

    command! -nargs=* -complete=customlist,RegisterComplete VSRegister DoRegisterAction(<f-args>)
enddef

## (Fuzzy) Find Files

cmd.AddOnSpaceHook('VSFind')

## (Live) Find Files

# def DoLiveFindComplete(A: string, L: string, C: number): list<any>
#     return live.DoComplete(A, L, C, 'find . \! \( -path "*/.*" -prune \) -type f -follow -name')
# enddef

## (Live) Grep

def DoLiveGrepComplete(A: string, L: string, C: number): list<any>
    var macos = has('macunix')
    var flags = macos ? '-REIHSins' : '-REIHins'
    var cmdstr = $'grep --color=never {flags}'
    # 'sh -c' is needed for {} shell substitution.
    return live.DoComplete(A, L, C, cmdstr .. ' --exclude="{.gitignore,.swp,.zwc,tags,./.git/*}"', 'sh -c')
enddef

## Buffers

cmd.AddOnSpaceHook('VSBuffer')
def BufferComplete(arglead: string, cmdline: string, cursorpos: number): list<any>
    return fuzzy.Complete(arglead, cmdline, cursorpos, function(Buffers, [false]))
enddef
def DoBufferAction(arglead: string = null_string)
    fuzzy.DoAction(arglead, (item) => {
        :exe $'b {item->type() == v:t_dict ? item.bufnr : item}'
    })
enddef
def Buffers(list_all_buffers: bool): list<any>
    var blist = list_all_buffers ? getbufinfo({buloaded: 1}) : getbufinfo({buflisted: 1})
    var buffer_list = blist->mapnew((_, v) => {
        return {bufnr: v.bufnr,
            text: (bufname(v.bufnr) ?? $'[{v.bufnr}: No Name]'),
            lastused: v.lastused}
    })->sort((i, j) => i.lastused > j.lastused ? -1 : i.lastused == j.lastused ? 0 : 1)
    # Alternate buffer first, current buffer second.
    if buffer_list->len() > 1 && buffer_list[0].bufnr == bufnr()
        [buffer_list[0], buffer_list[1]] = [buffer_list[1], buffer_list[0]]
    endif
    return buffer_list
enddef

## Code Artifacts

cmd.AddOnSpaceHook('VSArtifacts')
export def ArtifactsComplete(arglead: string, cmdline: string, cursorpos: number,
        patterns: list<string> = []): list<any>
    return fuzzy.Complete(arglead, cmdline, cursorpos, function(Artifacts, [patterns]))
enddef
export def DoArtifactsAction(arglead = null_string)
    fuzzy.DoAction(arglead, (item) => {
        exe $":{item.lnum}"
        normal! zz
    })
enddef
export def Artifacts(patterns: list<string>): list<any>
    var items = []
    for nr in range(1, line('$'))
        var line = getline(nr)
        for pat in patterns
            var name = line->matchstr(pat)
            if name != null_string
                items->add({text: name, lnum: nr})
                break
            endif
        endfor
    endfor
    return items->copy()->filter((_, v) => v.text !~ '^\s*#')
enddef

## MRU - Most Recently Used Files

cmd.AddOnSpaceHook('VSMru')
def MRUComplete(arglead: string, cmdline: string, cursorpos: number): list<any>
    return fuzzy.Complete(arglead, cmdline, cursorpos, MRU)
enddef
def DoMRUAction(arglead: string = null_string)
    fuzzy.DoAction(arglead, (item) => {
        :exe $'e {item}'
    })
enddef
def MRU(): list<any>
    var mru = v:oldfiles->copy()->filter((_, v) => filereadable(fnamemodify(v, ":p")))
    mru->map((_, v) => v->fnamemodify(':.'))
    return mru
enddef

## Keymap

cmd.AddOnSpaceHook('VSKeymap')
def KeymapComplete(arglead: string, cmdline: string, cursorpos: number): list<any>
    return fuzzy.Complete(arglead, cmdline, cursorpos, (): list<any> => {
        return execute('map')->split("\n")
    })
enddef
def DoKeymapAction(arglead: string = null_string)
    fuzzy.DoAction(arglead, (item) => {
        var m = item->matchlist('\v^(\a)?\s+(\S+)')
        if m->len() > 2
            var cmdstr = $'verbose {m[1]}map {m[2]}'
            var lines = execute(cmdstr)->split("\n")
            for line in lines
                m = line->matchlist('\v\s*Last set from (.+) line (\d+)')
                if !m->empty() && m[1] != null_string && m[2] != null_string
                    exe $"e +{str2nr(m[2])} {m[1]}"
                endif
            endfor
        endif
    })
enddef

## Global and Local Marks

cmd.AddOnSpaceHook('VSMark')
def MarkComplete(arglead: string, cmdline: string, cursorpos: number): list<any>
    return fuzzy.Complete(arglead, cmdline, cursorpos, (): list<any> => {
        return 'marks'->execute()->split("\n")->slice(1)
    })
enddef
def DoMarkAction(arglead: string = null_string)
    fuzzy.DoAction(arglead, (item) => {
        var mark = item->matchstr('\v^\s*\zs\S+')
        :exe $"normal! '{mark}"
    })
enddef

## Registers

cmd.AddOnSpaceHook('VSRegister')
def RegisterComplete(arglead: string, cmdline: string, cursorpos: number): list<any>
    return fuzzy.Complete(arglead, cmdline, cursorpos, (): list<any> => {
        return 'registers'->execute()->split("\n")->slice(1)
    })
enddef
def DoRegisterAction(arglead: string = null_string)
    fuzzy.DoAction(arglead, (item) => {
        var reg = item->matchstr('\v^\s*\S+\s+\zs\S+')
        :exe $'normal! {reg}p'
    })
enddef

##

export def Disable()
    # XXX
    for c in ['VSFind', 'VSLiveFind', 'VSBuffer', 'VSMru']
        if exists($":{c}") == 2
            :exec $'delcommand {c}'
        endif
    endfor
enddef

:defcompile  # Debug: Just so that compilation errors show up when script is loaded.
             # Otherwise, compilation is postponed until <tab> completion.


# vim: tabstop=8 shiftwidth=4 softtabstop=4 expandtab