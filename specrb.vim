" Vim syntax file
" Language: spec.rb
" Maintainer: Michal Jirku <box@wejn.org>
" Last Change: 2013-02-09
"
" Work in progress...

if version < 600
	syntax clear
elseif exists("b:current_syntax")
	finish
endif

syn match specrbTitle "^!\s*.*"
syn match specrbComment "^#.*"
syn match specrbSection "^=\+\s.*"
syn keyword specrbKeywords XXX TODO FIXME

syn match specrbList "^\*"
syn match specrbDefListStart "^:" nextgroup=specrbDefListTerm skipwhite
syn match specrbDefListTerm "[^=]*" nextgroup=specrbDefListSep contained skipwhite contains=specrbPre,specrbHilite,specrbKeywords,specrbBR
syn match specrbDefListSep "=" nextgroup=specrbDefListDef contained skipwhite
syn match specrbDefListDef ".*" contained skipwhite contains=specrbPre,specrbHilite,specrbKeywords,specrbBR

syn region specrbCodeBlock start="^{{{" end="^}}}" fold

syn match specrbPre "`[^`]*`"
syn match specrbHilite "\^[^^]\+\^"

syn match specrbLink "<[^>]*>"

syn match specrbBR ";;"

syn region specrbTable start="^|" end="$" contains=specrbTableSep,specrbPre,specrbHilite,specrbKeywords,specrbBR
syn match specrbTableSep "|" contained

hi def link specrbTitle		Type
hi def link specrbComment	Comment
hi def link specrbSection	Function
hi def link specrbKeywords	Todo
hi specrbBR	ctermfg=5
hi def link specrbCodeBlock	Constant
hi def link specrbDefListStart	PreProc
hi def link specrbDefListSep	PreProc
hi def link specrbList	PreProc
hi def link specrbPre	Constant
hi specrbHilite	term=reverse cterm=reverse ctermfg=3 guibg=DarkMagenta
hi def link specrbLink Statement
hi def link specrbTableSep Underlined

let b:current_syntax = "specrb"
