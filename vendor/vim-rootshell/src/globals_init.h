/* vi:set ts=8 sts=4 sw=4 noet:
 *
 * VIM - Vi IMproved	by Bram Moolenaar
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 */

/*
 * Initialization of global variables for Vim 9.1
 * Used to reset thread-local global variables between vim invocations
 */

// Screen variables
Rows = 24L;
Columns = 80;
ScreenLines = NULL;
ScreenAttrs = NULL;
ScreenCols = NULL;
LineOffset = NULL;
LineWraps = NULL;
ScreenLinesUC = NULL;
Screen_mco = 0;
ScreenLines2 = NULL;
current_ScreenLine = NULL;
screen_cur_row = 0;
screen_cur_col = 0;
redrawing_for_callback = 0;
TabPageIdxs = NULL;
#ifdef FEAT_PROP_POPUP
popup_mask = NULL;
popup_mask_next = NULL;
popup_transparent = NULL;
popup_mask_refresh = TRUE;
popup_mask_tab = NULL;
screen_zindex = 0;
#endif
screen_Rows = 0;
screen_Columns = 0;
screen_opacity_popup = NULL;

// Key modifiers
mod_mask = 0;
vgetc_mod_mask = 0;
vgetc_char = 0;

// Command line and redraw state
cmdline_row = 0;
cmdline_col_off = 0;
cmdline_width = 0;
redraw_cmdline = FALSE;
redraw_mode = FALSE;
clear_cmdline = FALSE;
mode_displayed = FALSE;
no_win_do_lines_ins = FALSE;
#if defined(FEAT_CRYPT) || defined(FEAT_EVAL)
cmdline_star = FALSE;
#endif
exec_from_reg = FALSE;
screen_cleared = FALSE;
dollar_vcol = -1;

// Insert mode completion
edit_submode = NULL;
edit_submode_pre = NULL;
edit_submode_extra = NULL;
edit_submode_highl = 0;

#ifdef FEAT_RIGHTLEFT
cmdmsg_rl = FALSE;
#endif

// Message variables
msg_col = 0;
msg_row = 0;
msg_scrolled = 0;
msg_scrolled_ign = FALSE;
keep_msg = NULL;
keep_msg_attr = 0;
keep_msg_more = FALSE;
need_fileinfo = FALSE;
msg_scroll = FALSE;
msg_didout = FALSE;
msg_didany = FALSE;
msg_nowait = FALSE;
emsg_off = 0;
info_message = FALSE;
msg_hist_off = FALSE;

#ifdef FEAT_EVAL
need_clr_eos = FALSE;
emsg_skip = 0;
emsg_severe = FALSE;
emsg_assert_fails_msg = NULL;
emsg_assert_fails_lnum = 0;
emsg_assert_fails_context = NULL;
did_endif = FALSE;
#endif

did_emsg = 0;
#ifdef FEAT_EVAL
did_emsg_silent = 0;
did_emsg_def = 0;
did_emsg_cumul = 0;
called_vim_beep = 0;
uncaught_emsg = 0;
#endif
did_emsg_syntax = 0;
called_emsg = 0;
in_echowindow = 0;
ex_exitval = 0;
emsg_on_display = FALSE;
rc_did_emsg = FALSE;

no_wait_return = 0;
need_wait_return = 0;
did_wait_return = FALSE;
need_maketitle = TRUE;

quit_more = FALSE;
#if defined(UNIX) || defined(VMS) || defined(MACOS_X) || defined(AMIGA)
newline_on_exit = FALSE;
intr_char = 0;
#endif
#if (defined(UNIX) || defined(VMS)) && defined(FEAT_X11)
x_no_connect = FALSE;
# if defined(FEAT_CLIENTSERVER)
x_force_connect = FALSE;
# endif
#endif
ex_keep_indent = FALSE;
vgetc_busy = 0;

didset_vim = FALSE;
didset_vimruntime = FALSE;

lines_left = -1;
msg_no_more = FALSE;

// Execution stack
exestack = (garray_T) {0, 0, sizeof(estack_T), 50, NULL};

// Script context
#ifdef FEAT_EVAL
current_sctx = (sctx_T) {0, 0, 0, 0};
estack_compiling = FALSE;
ex_nesting_level = 0;
debug_break_level = -1;
debug_did_msg = FALSE;
debug_tick = 0;
debug_backtrace_level = 0;
# ifdef FEAT_PROFILE
do_profiling = PROF_NONE;
# endif
script_items = (garray_T) {0, 0, sizeof(scriptitem_T *), 20, NULL};

// Exception handling
current_exception = NULL;
did_throw = FALSE;
need_rethrow = FALSE;
check_cstack = FALSE;
trylevel = 0;
force_abort = FALSE;
msg_list = NULL;
suppress_errthrow = FALSE;
caught_stack = NULL;

// Garbage collection
may_garbage_collect = FALSE;
want_garbage_collect = FALSE;
garbage_collect_at_exit = FALSE;

did_source_packages = FALSE;
#endif

// Hash table
hash_removed = NUL;

// Terminal and color
scroll_region = FALSE;
t_colors = 0;

// Highlight completion flags
include_none = 0;
include_default = 0;
include_link = 0;

// Search highlighting
#ifdef FEAT_SEARCH_EXTRA
search_hl_has_cursor_lnum = 0;
no_hlsearch = FALSE;
#endif
highlight_match = FALSE;
search_match_lines = 0;
search_match_endcol = 0;
#ifdef FEAT_SEARCH_EXTRA
search_first_line = 0;
search_last_line = MAXLNUM;
#endif

no_smartcase = FALSE;

// File timestamp checking
need_check_timestamps = FALSE;
did_check_timestamps = FALSE;
no_check_timestamps = 0;

#ifdef FEAT_TERMINAL
skip_term_loop = FALSE;
#endif

#ifdef FEAT_GUI
use_gvimrc = NULL;
#endif

// Terminal colors
cterm_normal_fg_color = 0;
cterm_normal_fg_bold = 0;
cterm_normal_bg_color = 0;
cterm_normal_ul_color = 0;
#ifdef FEAT_TERMGUICOLORS
cterm_normal_fg_gui_color = INVALCOLOR;
cterm_normal_bg_gui_color = INVALCOLOR;
cterm_normal_ul_gui_color = INVALCOLOR;
#endif
#ifdef FEAT_TERMRESPONSE
is_mac_terminal = FALSE;
#endif

// Autocommands
autocmd_busy = FALSE;
autocmd_no_enter = FALSE;
autocmd_no_leave = FALSE;
tabpage_move_disallowed = FALSE;

au_new_curbuf = (bufref_T) {NULL, 0, 0};
au_pending_free_buf = NULL;
au_pending_free_win = NULL;

// Mouse state
mouse_row = 0;
mouse_col = 0;
mouse_past_bottom = FALSE;
mouse_past_eol = FALSE;
mouse_dragging = 0;
#if defined(FEAT_MOUSE_DEC)
WantQueryMouse = FALSE;
#endif

#ifdef FEAT_GUI
need_mouse_correct = FALSE;
gui_prev_topline = 0;
# ifdef FEAT_DIFF
gui_prev_topfill = 0;
# endif
#endif

#ifdef FEAT_MOUSESHAPE
drag_status_line = FALSE;
postponed_mouseshape = FALSE;
drag_sep_line = FALSE;
#endif

#ifdef FEAT_DIFF
diff_context = 6;
linematch_lines = 0;
diff_foldcolumn = 2;
diff_need_scrollbind = FALSE;
#endif

// Screen update flags
updating_screen = FALSE;
redraw_not_allowed = FALSE;
redraw_listeners = NULL;
inside_redraw_on_start_cb = false;

#ifdef MESSAGE_QUEUE
dont_parse_messages = FALSE;
#endif

#ifdef FEAT_MENU
root_menu = NULL;
sys_menu = FALSE;
#endif

#ifdef FEAT_GUI
# ifdef FEAT_MENU
current_menu = NULL;
force_menu_update = FALSE;
# endif
# ifdef FEAT_GUI_TABLINE
current_tab = 0;
current_tabmenu = 0;
# endif
current_scrollbar = 0;
scrollbar_value = 0;
found_reverse_arg = FALSE;
font_argument = NULL;
# ifdef FEAT_GUI_GTK
background_argument = NULL;
foreground_argument = NULL;
# endif
hold_gui_events = 0;
new_pixel_width = 0;
new_pixel_height = 0;
gui_win_x = -1;
gui_win_y = -1;
#endif

#ifdef FEAT_CLIPBOARD
clip_unnamed = 0;
clip_autoselect_star = FALSE;
clip_autoselect_plus = FALSE;
clip_autoselectml = FALSE;
clip_html = FALSE;
clip_provider = NULL;
clip_exclude_prog = NULL;
clip_unnamed_saved = 0;
#endif

// Windows and buffers
firstwin = NULL;
lastwin = NULL;
prevwin = NULL;
curwin = NULL;

// Autocommand windows
#ifdef DO_INIT
{
    int aucmd_i;
    for (aucmd_i = 0; aucmd_i < AUCMD_WIN_COUNT; ++aucmd_i)
    {
	aucmd_win[aucmd_i].auc_win = NULL;
	aucmd_win[aucmd_i].auc_win_used = FALSE;
    }
}
#endif

#ifdef FEAT_PROP_POPUP
first_popupwin = NULL;
popup_dragwin = NULL;
popup_visible = FALSE;
popup_uses_mouse_move = FALSE;
text_prop_frozen = 0;
ignore_text_props = FALSE;
#endif

pum_will_redraw = FALSE;

// Window frame
topframe = NULL;

// Tab pages
first_tabpage = NULL;
curtab = NULL;
lastused_tabpage = NULL;
redraw_tabline = FALSE;

#if defined(FEAT_TABPANEL)
redraw_tabpanel = FALSE;
#endif

// Buffers
firstbuf = NULL;
lastbuf = NULL;
curbuf = NULL;

mf_dont_release = FALSE;

// Argument list
max_alist_id = 0;
arg_had_last = FALSE;

// Ruler and status
ru_col = 0;
#ifdef FEAT_STL_OPT
ru_wid = 0;
#endif
sc_col = 0;

#ifdef TEMPDIRNAMES
# if defined(UNIX) && defined(HAVE_FLOCK) && (defined(HAVE_DIRFD) || defined(__hpux))
vim_tempdir_dp = NULL;
# endif
vim_tempdir = NULL;
#endif

// Startup and exit state
starting = NO_SCREEN;
exiting = FALSE;
really_exiting = FALSE;
v_dying = 0;
stdout_isatty = TRUE;

#if defined(FEAT_AUTOCHDIR)
test_autochdir = FALSE;
#endif
last_chdir_reason = NULL;
#if defined(EXITFREE)
entered_free_all_mem = FALSE;
#endif
full_screen = FALSE;

restricted = FALSE;
secure = FALSE;

textlock = 0;
curbuf_lock = 0;
allbuf_lock = 0;
#ifdef HAVE_SANDBOX
sandbox = 0;
#endif

silent_mode = FALSE;

// Visual mode
VIsual_active = FALSE;
VIsual_select = FALSE;
VIsual_select_reg = 0;
VIsual_select_exclu_adj = FALSE;
restart_VIsual_select = 0;
VIsual_reselect = 0;
VIsual_mode = 'v';
redo_VIsual_busy = FALSE;

// Visual reselection
resel_VIsual_mode = NUL;
resel_VIsual_line_count = 0;
resel_VIsual_vcol = 0;

// Paste tracking
#ifdef DO_INIT
where_paste_started = (pos_T) {0, 0, 0};
#endif

// Auto-indent
did_ai = FALSE;
ai_col = 0;
end_comment_pending = NUL;

// Scrollbind
did_syncbind = FALSE;

// Smart indent
did_si = FALSE;
can_si = FALSE;
can_si_back = FALSE;

old_indent = 0;

// Cursor position before formatting
#ifdef DO_INIT
saved_cursor = (pos_T) {0, 0, 0};
#endif

// Insert mode
#ifdef DO_INIT
Insstart = (pos_T) {0, 0, 0};
Insstart_orig = (pos_T) {0, 0, 0};
#endif

// Virtual replace mode
orig_line_count = 0;
vr_lines_changed = 0;

// Character encoding
enc_dbcs = 0;
enc_unicode = 0;
enc_utf8 = FALSE;
enc_latin1like = TRUE;
#if defined(MSWIN) || defined(FEAT_CYGWIN_WIN32_CLIPBOARD)
enc_codepage = -1;
enc_latin9 = FALSE;
#endif
has_mbyte = 0;

// Multi-byte function pointers
mb_ptr2len = latin_ptr2len;
mb_ptr2len_len = latin_ptr2len_len;
mb_char2len = latin_char2len;
mb_char2bytes = latin_char2bytes;
mb_ptr2cells = latin_ptr2cells;
mb_ptr2cells_len = latin_ptr2cells_len;
mb_char2cells = latin_char2cells;
mb_off2cells = latin_off2cells;
mb_ptr2char = latin_ptr2char;
mb_head_off = latin_head_off;

#ifdef FEAT_XIM
# ifdef FEAT_GUI_GTK
xic = NULL;
preedit_start_col = MAXCOL;
preedit_end_col = MAXCOL;
xim_changed_while_preediting = FALSE;
# else
xic = NULL;
# endif
# ifdef FEAT_GUI
xim_fg_color = INVALCOLOR;
xim_bg_color = INVALCOLOR;
# endif
#endif

// Vim state
State = MODE_NORMAL;
#ifdef FEAT_EVAL
debug_mode = FALSE;
#endif

finish_op = FALSE;
opcount = 0;
motion_force = 0;

// Ex mode
exmode_active = 0;
pending_exmode_active = FALSE;
ex_no_reprint = FALSE;

// Recording and executing
reg_recording = 0;
reg_executing = 0;
pending_end_reg_executing = FALSE;

// Keyboard protocol state
seenModifyOtherKeys = FALSE;
modify_otherkeys_state = MOKS_INITIAL;
kitty_protocol_state = KKPS_INITIAL;

// Mapping state
no_mapping = FALSE;
no_zero_mapping = 0;
allow_keys = FALSE;
no_reduce_keys = FALSE;
no_u_sync = 0;
#ifdef FEAT_EVAL
u_sync_once = 0;
#endif

// Insert mode restart
restart_edit = 0;
arrow_used = 0;
ins_at_eol = FALSE;

no_abbr = TRUE;

#ifdef USE_EXE_NAME
exe_name = NULL;
#endif

#ifdef USE_ON_FLY_SCROLL
dont_scroll = FALSE;
#endif
mapped_ctrl_c = FALSE;
ctrl_c_interrupts = TRUE;

// Command modifiers
#ifdef FEAT_EVAL
is_export = FALSE;
#endif

// Message control
msg_silent = 0;
emsg_silent = 0;
#ifdef FEAT_EVAL
emsg_silent_def = 0;
silence_w23_w24_msg = 0;
#endif
emsg_noredir = 0;
cmd_silent = FALSE;

in_assert_fails = FALSE;

// Swap file
swap_exists_action = SEA_NONE;
swap_exists_did_quit = FALSE;

IObuff = NULL;
NameBuff = NULL;

RedrawingDisabled = 0;

readonlymode = FALSE;
recoverymode = FALSE;

// Type-ahead buffer
#ifdef DO_INIT
typebuf = (typebuf_T) {NULL, NULL, 0, 0, 0, 0, 0, 0, 0};
#endif
typebuf_was_empty = FALSE;

ex_normal_busy = 0;
#ifdef FEAT_EVAL
in_feedkeys = 0;
#endif
ex_normal_lock = 0;

#ifdef FEAT_EVAL
ignore_script = FALSE;
#endif
stop_insert_mode = 0;

KeyTyped = 0;
KeyStuffed = 0;
#ifdef HAVE_INPUT_METHOD
vgetc_im_active = 0;
#endif
maptick = 0;

// Redraw flags
must_redraw = 0;
skip_redraw = FALSE;
do_redraw = FALSE;
#ifdef FEAT_DIFF
need_diff_redraw = 0;
#endif
#ifdef FEAT_RELTIME
redrawtime_limit_set = FALSE;
#endif

need_highlight_changed = TRUE;

// Script I/O
curscript = 0;
scriptout = NULL;
read_cmd_fd = 0;

// Interrupt handling
got_int = FALSE;
got_sigusr1 = FALSE;

#ifdef USE_TERM_CONSOLE
term_console = FALSE;
#endif
termcap_active = FALSE;
cur_tmode = TMODE_COOK;
bangredo = FALSE;
searchcmdlen = 0;

#ifdef FEAT_SYN_HL
reg_do_extmatch = 0;
re_extmatch_in = NULL;
re_extmatch_out = NULL;
#endif

// Error messages
did_outofmem_msg = FALSE;
did_swapwrite_msg = FALSE;

// Undo state
undo_off = FALSE;

// Global command state
global_busy = 0;
listcmd_busy = FALSE;
need_start_insertmode = FALSE;

// Command line
#if defined(FEAT_EVAL)
#ifdef DO_INIT
{
    int i;
    for (i = 0; i < MODE_MAX_LENGTH; ++i)
	last_mode[i] = (i == 0) ? 'n' : NUL;
}
#endif
#endif
last_cmdline = NULL;
repeat_cmdline = NULL;
new_last_cmdline = NULL;
autocmd_fname = NULL;
autocmd_fname_full = 0;
autocmd_bufnr = 0;
autocmd_match = NULL;
aucmd_cmdline_changed_count = 0;

// Cursor events
did_cursorhold = TRUE;
#ifdef DO_INIT
last_cursormoved = (pos_T) {0, 0, 0};
#endif

// Window splitting
postponed_split = 0;
postponed_split_flags = 0;
postponed_split_tab = 0;
#ifdef FEAT_QUICKFIX
g_do_tagpreview = 0;
#endif
g_tag_at_cursor = FALSE;

replace_offset = 0;

escape_chars = (char_u *)" \t\\\"|";

keep_help_flag = FALSE;

empty_option = (char_u *)"";

// Redirection
redir_off = FALSE;
redir_fd = NULL;
#ifdef FEAT_EVAL
redir_reg = 0;
redir_vname = 0;
redir_execute = 0;
#endif

// Wild menu
save_p_ls = -1;
save_p_wmh = -1;
wild_menu_showing = 0;

#ifdef MSWIN
found_register_arg = FALSE;
#endif

homedir = NULL;
globaldir = NULL;

#ifdef FEAT_FOLDING
disable_fold_update = 0;
#endif

// Keymodel flags
km_stopsel = FALSE;
km_startsel = FALSE;

// Command-line window
cmdwin_type = 0;
cmdwin_result = 0;
cmdwin_buf = NULL;
cmdwin_win = NULL;

// Substitution
sub_nsubs = 0;
sub_nlines = 0;

#ifdef FEAT_EVAL
substitute_instr = NULL;
#endif

#if defined(FEAT_STL_OPT)
stl_syntax = 0;
#endif

#if defined(FEAT_BEVAL) && !defined(NO_X11_INCLUDES)
balloonEval = NULL;
balloonEvalForTerm = FALSE;
# if defined(FEAT_NETBEANS_INTG)
bevalServers = 0;
# endif
#endif

#ifdef FEAT_XCLIPBOARD
xterm_display = NULL;
xterm_display_allocated = FALSE;
xterm_dpy = NULL;
#endif
#if defined(FEAT_XCLIPBOARD) || defined(FEAT_GUI_X11)
app_context = (XtAppContext)NULL;
#endif

#ifdef FEAT_GUI_GTK
gtk_socket_id = 0;
echo_wid_arg = FALSE;
#endif

#ifdef FEAT_GUI_MSWIN
win_socket_id = 0;
#endif

#if defined(FEAT_CLIENTSERVER) || defined(FEAT_EVAL)
typebuf_was_filled = FALSE;
#endif

#ifdef FEAT_CLIENTSERVER
serverName = NULL;
# ifdef FEAT_X11
commWindow = None;
clientWindow = None;
commProperty = None;
serverDelayedStartName = NULL;
# elif defined(MSWIN)
clientWindow = 0;
# endif
#endif

#if defined(UNIX) || defined(VMS)
term_is_xterm = FALSE;
#endif

#ifdef BACKSLASH_IN_FILENAME
psepc = '\\';
psepcN = '/';
pseps[0] = '\\';
pseps[1] = 0;
#endif

virtual_op = MAYBE;

#ifdef FEAT_SYN_HL
display_tick = 0;
#endif

#ifdef FEAT_SPELL
spell_redraw_lnum = 0;
#endif

#ifdef FEAT_CONCEAL
need_cursor_line_redraw = FALSE;
#endif

#ifdef USE_MCH_ERRMSG
error_ga = (garray_T) {0, 0, 0, 0, NULL};
#endif

#ifdef FEAT_NETBEANS_INTG
netbeansArg = NULL;
netbeansFireChanges = 1;
netbeansForcedQuit = 0;
netbeansReadFile = 1;
netbeansSuppressNoLines = 0;
#endif

#ifdef USE_XSMP
xsmp_icefd = -1;
#endif

// starttime removed - doesn't exist in Vim 9.1

#ifdef STARTUPTIME
time_fd = NULL;
#endif

vim_ignored = 0;
vim_ignoredp = NULL;

#ifdef FEAT_EVAL
alloc_fail_id = aid_none;
alloc_fail_countdown = -1;
alloc_fail_repeat = 0;

disable_char_avail_for_testing = FALSE;
disable_redraw_for_testing = FALSE;
ignore_redraw_flag_for_testing = FALSE;
nfa_fail_for_testing = FALSE;
no_query_mouse_for_testing = FALSE;

in_free_unref_items = FALSE;
#endif

#ifdef FEAT_TIMERS
did_add_timer = FALSE;
timer_busy = 0;
#endif

#ifdef FEAT_BEVAL_TERM
bevalexpr_due_set = FALSE;
profile_zero(&bevalexpr_due);
#endif

#ifdef FEAT_EVAL
time_for_testing = 0;
did_echo_string_emsg = FALSE;
eval_lavars_used = NULL;
#endif

#ifdef MSWIN
ctrl_break_was_pressed = FALSE;
g_hinst = NULL;
#endif

#if defined(FEAT_JOB_CHANNEL)
did_repeated_msg = 0;
#endif
