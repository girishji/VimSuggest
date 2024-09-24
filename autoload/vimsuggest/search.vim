vim9script

import autoload './options.vim' as opt
import autoload './popup.vim'

var options = opt.options.search

class Properties
    # Note: 'public' var is read/write, otherwise read-only; if var begins with '_'
    #   (protected) no read/write from outside class
    public var items: list<any>       #  items shown in popup menu
    public var candidates: list<any>  #  candidates for completion (could be phrases)
    public var context = ''           #  cached cmdline contents
    public var firstmatch = []        #  workaround for vim issue 12538
    var pmenu: popup.PopupMenu = null_object
    var isfwd: bool                   #  true for '/' and false for '?'
    var async: bool
    var curpos: list<any>

    def new()
        this.isfwd = getcmdtype() == '/' ? true : false
        this.pmenu = popup.PopupMenu.new(FilterFn, CallbackFn, options.popupattrs, options.pum)
        # Issue: Due to vim issue 12538 highlighting has to be provoked explicitly during
        # async search. The redraw command causes some flickering of highlighted
        # text. So do async search only when file is large.
        this.async = line('$') < 1500 ? false : options.async
        if this.async
            this.curpos = getcurpos()
        endif
    enddef

    def Clear()
        this.pmenu.Close()
    enddef
endclass

var props: Properties

export def Setup()
    if options.enable
        augroup VimSuggestSearchAutocmds | autocmd!
            autocmd CmdlineEnter    /,\?  {
                props = Properties.new()
                EnableCmdline()
            }
            autocmd CmdlineChanged  /,\?  options.alwayson ? Complete() : TabComplete()
            autocmd CmdlineLeave    /,\?  {
                if props != null_object
                    props.Clear()
                    props = null_object
                endif
            }
        augroup END
    endif
enddef

export def Teardown()
    augroup VimSuggestSearchAutocmds | autocmd!
    augroup END
enddef

def EnableCmdline()
    autocmd! VimSuggestSearchAutocmds CmdlineChanged /,\? options.alwayson ? Complete() : TabComplete()
enddef

def DisableCmdline()
    autocmd! VimSuggestSearchAutocmds CmdlineChanged /,\?
enddef

def TabComplete()
    var lastcharpos = getcmdpos() - 2
    if getcmdline()[lastcharpos] ==? "\<tab>"
        setcmdline(getcmdline()->slice(0, lastcharpos))
        Complete()
    endif
enddef

def Complete()
    var p = props
    var context = getcmdline()->strpart(0, getcmdpos() - 1)
    if context == '' || context =~ '^\s\+$'
        return
    endif
    # note:
    # 1) when pasting text from clipboard, CompleteChanged event is called
    #    only once instead of for every character pasted.
    # 2) when pasting a long line of text, search appears to be slow for the first time
    #    (likely because functions are getting compiled). it will be fast afterwards.
    p.context = context
    p.candidates = []
    p.items = []
    if p.async
        var attr = {
            starttime: reltime(),
            context: context,
            batches: Batches(),
            index: 0,
        }
        if &incsearch # find first match to highlight (vim issue 12538)
            attr->extend({firstmatch: GetFirstMatch()})
        endif
        SearchWorker(attr)
    else
        p.items = options.fuzzy ? BufFuzzyMatches() : Batches()->BufMatches()->MakeUnique()->Itemify()
        if len(p.items[0]) > 0
            ShowPopupMenu()
        endif
    endif
enddef

def ShowPopupMenu()
    var p = props
    p.pmenu.SetText(p.context, p.items)
    p.pmenu.Show()
    # note: if command-line is not disabled here, it will receive keys before
    # popup receives. this prevents popup from handling <tab> for instance.
    DisableCmdline()
enddef

def PostSelectItem(index: number)
    var p = props
    setcmdline(p.items[0][index]->escape('~/'))
    :redraw  # needed for <tab> selected menu item highlighting to work
enddef

def FilterFn(winid: number, key: string): bool
    var p = props
    IncSearchHighlightClear()
    # note: do not include arrow keys since they are used for history lookup
    if key == "\<Tab>" || key == "\<C-n>"
        p.pmenu.SelectItem('j', PostSelectItem) # next item
    elseif key == "\<S-Tab>" || key == "\<C-p>"
        p.pmenu.SelectItem('k', PostSelectItem) # prev item
    elseif key == "\<C-e>"
        p.pmenu.Hide()
        setcmdline('')
        feedkeys(p.context, 'n')
        :redraw!
        timer_start(0, (_) => EnableCmdline()) # timer will que this after feedkeys
    elseif key == "\<CR>" || key == "\<ESC>"
        EnableCmdline()
        return false
    else
        p.pmenu.Hide()
        # key->ProcessKey()
        
        # note: enable command-line so that it handles the keys first. this is
        # more conservative since we do not want to deal with various control
        # characters and up/down arrow keys (history recall).
        EnableCmdline()
        return false # Let vim's usual mechanism (ex. search highlighting) handle this
    endif
    return true
enddef

def CallbackFn(winid: number, result: any)
    IncSearchHighlightClear()
    if result == -1 # popup force closed due to <c-c> or cursor mvmt
        EnableCmdline()
        feedkeys("\<c-c>", 'n')
    endif
enddef

# return a list containing range of lines to search
def Batches(): list<any>
    var p = props
    var range = max([10, options.range])
    var ibelow = []
    var iabove = []
    var startl = line('.')
    while startl <= line('$')
        if p.isfwd
            ibelow->add({startl: startl, endl: min([startl + range, line('$')])})
        else
            ibelow->insert({startl: startl, endl: min([startl + range, line('$')])})
        endif
        startl += range
    endwhile
    startl = 1
    while startl <= line('.')
        if p.isfwd
            iabove->add({startl: startl, endl: min([startl + range, line('.')])})
        else
            iabove->insert({startl: startl, endl: min([startl + range, line('.')])})
        endif
        startl += range
    endwhile
    return p.isfwd ? ibelow + iabove : iabove + ibelow
enddef

def MakeUnique(lst: list<any>): list<any>
    var unq = []
    var found = {} # uniq() does not work when list is not sorted, so remove duplicates using a set
    for item in lst
        if !found->has_key(item.text)
            found[item.text] = 1
            unq->add(item)
        endif
    endfor
    return unq
enddef

def Itemify(matches: list<any>): list<any>
    var text = []
    var colnum = []
    var mlen = []
    var has_submatches = !matches->empty() && matches[0]->has_key('submatches')
    for item in matches
        text->add(item.text)
        if has_submatches
            colnum->add([item.submatches[0]->len()])
            mlen->add(item.submatches[1]->len())
        endif
    endfor
    return has_submatches ? [text, colnum, mlen] : [text]
enddef

def GetFirstMatch(): list<any>
    var p = props
    var pos = []
    var save_cursor = getcurpos()
    setpos('.', p.curpos)
    try
        var [blnum, bcol] = p.context->searchpos(p.isfwd ? 'nw' : 'nwb')
        if [blnum, bcol] != [0, 0]
            var [elnum, ecol] = p.context->searchpos(p.isfwd ? 'nwe' : 'nwbe')
            if [elnum, ecol] != [0, 0]
                if blnum == elnum
                    pos = [[blnum, bcol, ecol - bcol + 1]]
                else
                    pos = [[blnum, bcol, 1000]]
                    for lnum in range(blnum + 1, elnum - 1)
                        pos->add([lnum])
                    endfor
                    pos->add([elnum, 1, ecol])
                endif
            endif
        endif
    catch
        # E33 is thrown when '~' is the first character of search. '~' stands
        # for previously substituted pattern in ':s'.
    endtry
    setpos('.', save_cursor)
    return pos
enddef

# return a list of strings (can have spaces) that match the pattern
def BufMatches(batches: list<dict<any>>): list<any>
    var p = props
    if p.context =~ '[^\\]\+\\n\|^\\n'  # contains a newline char
        var save_cursor = getcurpos()
        if p.async
            var startl = p.isfwd ? max([1, batches[0].startl - 5]) : min([line('$'), batches[0].endl + 5])
            cursor(startl, p.isfwd ? 1 : 1000)
        endif
        var matches = BufMatchMultiLine(batches[0])
        setpos('.', save_cursor)
        return matches
    else
        return BufMatchLine(batches)
    endif
enddef

def BufMatchLine(batches: list<dict<any>>): list<any>
    var p = props
    var pat = (p.context =~ '\(\\s\| \)' ? '\(\)' : '\(\k*\)') .. $'\({p.context}\)\(\k*\)'
    var matches = []
    var timeout = max([10, options.timeout])
    var starttime = reltime()
    try
        for batch in batches
            var m = bufnr()->matchbufline(pat, batch.startl, batch.endl, {submatches: true})
            if m->len() > 0 && m[0].submatches[1] =~ '^\s*$' # ignore searches for only space characters
                break
            endif
            if !p.isfwd
                m->reverse()
            endif
            matches->extend(m)
            if (starttime->reltime()->reltimefloat() * 1000) > timeout
                break
            endif
        endfor
    catch # '\' throws E55
        # echom v:exception
    endtry
    return matches
enddef

# search across line breaks. less efficient and probably not very useful.
# note: not supporting syntax highlighting for now.
def BufMatchMultiLine(batch: dict<any>): list<any>
    var p = props
    var timeout = max([10, options.timeout])
    var flags = p.async ? (p.isfwd ? '' : 'b') : (p.isfwd ? 'w' : 'wb')
    var pattern = p.context =~ '\s' ? $'{p.context}\k*' : $'\k*{p.context}\k*'
    var [lnum, cnum] = [0, 0]
    var [startl, startc] = [0, 0]
    var stopl = 0
    if p.async
        stopl = p.isfwd ? batch.endl : batch.startl
    endif
    try
        if p.async
            [lnum, cnum] = pattern->searchpos(flags, stopl)
        else
            [lnum, cnum] = pattern->searchpos(flags, 0, timeout)
            [startl, startc] = [lnum, cnum]
        endif
    catch # '*' with magic can throw E871
        # echom v:exception
        return []
    endtry
    var matches = []
    var found = {}
    var starttime = reltime()
    while [lnum, cnum] != [0, 0]
        var [endl, endc] = pattern->searchpos('ceW') # end of matching string
        var lines = getline(lnum, endl)
        var mstr = '' # fragment that matches pattern (can be multiline)
        if lines->len() == 1
            mstr = lines[0]->strpart(cnum - 1, endc - cnum + 1)
        else
            var mlist = [lines[0]->strpart(cnum - 1)] + lines[1 : -2] + [lines[-1]->strpart(0, endc)]
            mstr = mlist->join('\n')
        endif
        if !found->has_key(mstr)
            found[mstr] = 1
            matches->add(mstr)
        endif
        cursor(lnum, cnum) # restore cursor to beginning of pattern, otherwise '?' does not work
        [lnum, cnum] = p.async ? pattern->searchpos(flags, stopl) :
            pattern->searchpos(flags, 0, timeout)

        if !p.async && ([startl, startc] == [lnum, cnum] ||
                (starttime->reltime()->reltimefloat() * 1000) > timeout)
            break
        endif
    endwhile
    return matches->mapnew((_, v) => {
        return {text: v}
    })
enddef

# return a list of strings that fuzzy match the pattern
def BufFuzzyMatches(): list<any>
    var p = props
    var found = {}
    var words = []
    var starttime = reltime()
    var batches = []
    const MaxLines = 5000 # on M1 it takes 100ms to process 9k lines
    if line('$') > MaxLines
        var lineend = min([line('.') + MaxLines, line('$')])
        batches->add({start: line('.'), end: lineend})
        var linestart = max([line('.') - MaxLines, 0])
        var remaining = line('.') + MaxLines - line('$')
        if linestart != 0 && remaining > 0
            linestart = max([linestart - remaining, 0])
        endif
        batches->add({start: linestart, end: line('.')})
    else
        batches->add({start: 1, end: line('$')})
    endif
    var timeout = max([10, options.timeout])
    var range = max([10, options.range])
    for batch in batches
        var linenr = batch.start 
        for line in getline(batch.start, batch.end)
            for word in line->split('\W\+')
                if !found->has_key(word) && word->len() > 1
                    found[word] = 1
                    words->add(word)
                endif
            endfor
            if timeout > 0 && linenr % range == 0 &&
                    starttime->reltime()->reltimefloat() * 1000 > timeout
                break
            endif
            linenr += 1
        endfor
    endfor
    var matches = words->matchfuzzypos(p.context, { matchseq: 1, limit: 100 }) # max 100 matches
    matches[2]->map((_, _) => 1)
    # convert character positions to byte index (needed by matchaddpos)
    matches[1]->map((idx, v) => {
        return v->mapnew((_, c) => matches[0][idx]->byteidx(c))
    })
    return matches
enddef

# workaround for vim issue 12538: https://github.com/vim/vim/issues/12538
var matchids = {sid: 0, iid: 0}
def IncSearchHighlight(firstmatch: list<any>, context: string)
    var show = false
    if &hlsearch
        matchids.sid = matchadd('Search', &ignorecase ? $'\c{context}' : context, 101)
        show = true
    endif
    if &incsearch && firstmatch != null_list
        matchids.iid = matchaddpos('IncSearch', firstmatch, 102)
        show = true
    endif
    if show
        :redraw
    endif
enddef

def IncSearchHighlightClear()
    var p = props
    if p.async
        if matchids.sid > 0
            matchids.sid->matchdelete()
            matchids.sid = 0
        endif
        if matchids.iid > 0
            matchids.iid->matchdelete()
            matchids.iid = 0
        endif
    endif
enddef

# a worker task for async search
def SearchWorker(attr: dict<any>, timer: number = 0)
    var p = props
    var context = getcmdline()->strpart(0, getcmdpos() - 1)
    var timeoutasync = max([10, options.timeoutasync])
    if context !=# attr.context ||
            (attr.starttime->reltime()->reltimefloat() * 1000) > timeoutasync ||
            attr.index >= attr.batches->len()
        return
    endif
    if attr.index == 0
        IncSearchHighlight(attr.firstmatch, context)
    endif
    var batch = attr.batches[attr.index]
    var matches = BufMatches([batch])
    p.candidates = MakeUnique(p.candidates + matches)
    p.items = Itemify(p.candidates)
    if len(p.items[0]) > 0
        ShowPopupMenu()
    endif
    attr.index += 1
    timer_start(0, function(SearchWorker, [attr]))
enddef

# vim: tabstop=8 shiftwidth=4 softtabstop=4